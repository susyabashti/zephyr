//! Phase 8 gate: the semantic layer (spec/semantic.md section 8) with a
//! deterministic fake engine — the suite never links or loads llama.cpp.
//!
//!   - ZDE1 layout: header fields byte by byte, chunk order, footer hash.
//!   - ZDE1 corruption: truncation, magic, version, order, footer.
//!   - Rebuild: deterministic (byte-identical after deletion), visible-only
//!     (private and redacted entries never enter a vector), bytes/entry.
//!   - Staleness: a head mismatch, an identity change, and a corrupt
//!     artifact are all "no vectors" — reads never serve or rebuild.
//!   - keywordHits: exact on the fixture (Phase 7 token rules).
//!   - RRF fusion: hand-computed scores, ties included.
//!   - cosine top-N: exact scores, ties by seq, cap.
//!   - contextPack: the hybrid list is the fusion order (distinct from the
//!     keyword order on this fixture); null hybrid keeps the Phase 7 bytes.

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const journal_mod = core.journal;
const view = core.view;
const embed = core.embed;
const dstore = core.dstore;

const Sha256 = std.crypto.hash.sha2.Sha256;

const BASE: u64 = 1_767_225_600_000; // 2026-01-01T00:00:00Z
const D0: i64 = 20454; // 2026-01-01

// ---------------------------------------------------------------- fixture

const Fixture = struct {
    journal: *journal_mod.Journal,
    io: Io,
    path: []const u8,

    fn init(allocator: Allocator, io: Io, dir_name: []const u8) !*Fixture {
        const self = try allocator.create(Fixture);
        errdefer allocator.destroy(self);
        const cwd = Dir.cwd();
        const cwd_path = try std.process.currentPathAlloc(io, allocator);
        const path = try allocator.print("{s}/{s}", .{ cwd_path, dir_name });
        errdefer allocator.free(path);
        const environ = std.process.Environ.Map.init(allocator);
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
        const j = try allocator.create(journal_mod.Journal);
        errdefer allocator.destroy(j);
        j.* = try journal_mod.Journal.open(allocator, io, &environ, path, true);
        self.* = .{ .journal = j, .io = io, .path = path };
        return self;
    }

    fn deinit(self: *Fixture, allocator: Allocator) void {
        self.journal.close();
        Dir.deleteTree(Dir.cwd(), self.io, self.path) catch |e| if (e != error.FileNotFound)
            std.debug.panic("could not clean up: {s}", .{@errorName(e)});
        _ = allocator; // the journal struct and path live in the arena
    }
};

/// The fixture: six records, one UTC day (2026-01-01).
///   seq 0: [work] "shipped the auth fix"          01:00
///   seq 1: private "PRIVATE-P8-MARKER-8f2b"       02:00
///   seq 2: "sensitive meeting notes"              03:00 (redacted below)
///   seq 3: "walked the dog"                       04:00
///   seq 4: redaction of seq 2                     05:00
///   seq 5: [work] "shipped the auth token fix"    06:00
/// Visible: 0, 3, 5.
fn fillFixture(allocator: Allocator, journal: *const journal_mod.Journal) !void {
    _ = try journal.appendRecord(allocator, .entry, 0, "shipped the auth fix", &.{"work"}, BASE + 3_600_000, 0, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "PRIVATE-P8-MARKER-8f2b", &.{"priv"}, BASE + 7_200_000, 0, true);
    _ = try journal.appendRecord(allocator, .entry, 0, "sensitive meeting notes", &.{"sensitive"}, BASE + 10_800_000, 0, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "walked the dog", &.{"dog"}, BASE + 14_400_000, 0, false);
    _ = try journal.redact(allocator, 2, BASE + 18_000_000, 0);
    _ = try journal.appendRecord(allocator, .entry, 0, "shipped the auth token fix", &.{"work"}, BASE + 21_600_000, 0, false);
}

fn visibleOf(allocator: Allocator, journal: *const journal_mod.Journal) !struct {
    result: journal_mod.VerifyResult,
    recs: journal_mod.Journal.RecordSet,
    visible: view.Visible,
} {
    const result = try journal.verify(allocator);
    if (!result.ok) std.debug.panic("fixture journal should verify", .{});
    const recs = try journal.collectRecords(allocator);
    const visible = try view.visibleEntries(allocator, recs.headers, recs.payloads);
    return .{ .result = result, .recs = recs, .visible = visible };
}

fn readArtifact(allocator: Allocator, journal: *const journal_mod.Journal, name: []const u8) !?[]u8 {
    return journal.readJournalFile(allocator, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// The `embed` item of a status report (the report always has exactly
/// one; a miss is a test bug).
fn embedItem(items: []const dstore.Artifact) *const dstore.Artifact {
    for (items) |*a| {
        if (std.mem.eql(u8, a.name, "embed")) return a;
    }
    std.debug.panic("status report has no embed item", .{});
}

// ---------------------------------------------------------------- fake engine

/// The deterministic fake engine: dim 16. The three visible fixture lines
/// map to pinned unit vectors, the query maps to normalize([0.25, 0.5,
/// 1.0]) — so the vector order for the fixture is [5, 3, 0] — and any
/// other text maps to a hash-derived normalized vector. The identity is a
/// function of the salt, so an "identity change" is one parameter away.
const FakeEngine = struct {
    const Dim: u32 = 16;

    const State = struct {
        allocator: Allocator,
        salt: []const u8,
        model_hash: [32]u8,
        identity: [32]u8,
    };

    fn init(allocator: Allocator, salt: []const u8) Allocator.Error!embed.Engine {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .salt = salt,
            .model_hash = digest("fake-model-v1"),
            .identity = digest(salt),
        };
        return embed.Engine{ .vtable = &vtable, .data = state };
    }

    fn digest(s: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        Sha256.hash(s, &out, .{});
        return out;
    }

    const vtable = embed.Engine.VTable{
        .embed = embedImpl,
        .identity = identityImpl,
        .modelHash = modelHashImpl,
        .dim = dimImpl,
        .deinit = deinitImpl,
    };

    fn stateOf(data: ?*anyopaque) *State {
        const unaligned: *align(1) State = @ptrCast(data.?);
        return @alignCast(unaligned);
    }

    /// One L2-normalized vector per text, in order (f64 accumulation, f32
    /// storage — the real engine's numerics contract).
    fn vectorOf(text: []const u8, kind: embed.Engine.Kind) [16]f32 {
        var raw: [16]f64 = undefined;
        if (kind == .query) {
            raw = .{ 0.25, 0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
        } else if (indexOf(text, "shipped the auth token fix") != null) {
            raw = .{ 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
        } else if (indexOf(text, "shipped the auth fix") != null) {
            raw = .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
        } else if (indexOf(text, "walked the dog") != null) {
            raw = .{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
        } else {
            for (0..16) |i| {
                raw[i] = (@as(f64, @floatFromInt(fnv64(text) % 1000 + 1)) + @as(f64, @floatFromInt(i))) / 1000;
            }
        }
        var norm: f64 = 0;
        for (raw) |r| norm += r * r;
        const scale = 1 / @sqrt(norm);
        var out: [16]f32 = undefined;
        for (0..16) |i| out[i] = @as(f32, @floatCast(raw[i] * scale));
        return out;
    }

    fn embedImpl(data: ?*anyopaque, allocator: Allocator, texts: []const []const u8, kind: embed.Engine.Kind) embed.EmbedError![][]f32 {
        _ = data;
        var out = std.ArrayList([]f32).empty;
        errdefer {
            for (out.items) |v| allocator.free(v);
            allocator.free(out.items);
        }
        for (texts) |text| {
            const v = vectorOf(text, kind);
            const owned = try allocator.alloc(f32, Dim);
            errdefer allocator.free(owned);
            @memcpy(owned, &v);
            try out.append(allocator, owned);
        }
        return out.toOwnedSlice(allocator);
    }

    fn identityImpl(data: ?*anyopaque) [32]u8 {
        return stateOf(data).identity;
    }

    fn modelHashImpl(data: ?*anyopaque) [32]u8 {
        return stateOf(data).model_hash;
    }

    fn dimImpl(data: ?*anyopaque) u32 {
        _ = data;
        return Dim;
    }

    fn deinitImpl(data: ?*anyopaque) void {
        const state = stateOf(data);
        state.allocator.destroy(state);
    }
};

fn fnv64(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |b| {
        h ^= b;
        h = h * 0x100000001b3;
    }
    return h;
}

// ---------------------------------------------------------------- ZDE1 layout

test "phase 8: ZDE1 layout — header fields, chunk order, footer" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const model_hash = FakeEngine.digest("fake-model-v1");
    const engine_id = FakeEngine.digest("fake-identity-v1");
    const head = [32]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };

    const seqs = try allocator.alloc(u64, 2);
    seqs[0] = 11;
    seqs[1] = 42;
    const vectors = try allocator.alloc(f32, 8);
    for (vectors, 0..) |*x, i| x.* = if (i % 2 == 0) 0.5 else -0.25;

    var store = embed.Store{
        .dim = 4,
        .chunk_count = 2,
        .model_hash = model_hash,
        .engine_id = engine_id,
        .head = head,
        .record_count = 7,
        .seq_min = 11,
        .seq_max = 42,
        .seqs = seqs,
        .vectors = vectors,
        .allocator = allocator,
    };
    const bytes = try embed.encode(allocator, &store);
    defer allocator.free(bytes);

    // The exact on-disk layout (spec/semantic.md section 5).
    try std.testing.expectEqual(@as(usize, embed.HeaderLen + embed.FooterLen + 2 * (8 + 4 * 4)), bytes.len);
    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 'Z', 'D', 'E', '1' });
    try std.testing.expectEqual(@as(u8, 1), bytes[4]);
    try std.testing.expectEqual(@as(u8, 0), bytes[5]);
    try std.testing.expectEqualSlices(u8, bytes[6..8], &[_]u8{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 4), le32(bytes[8..12])); // dim
    try std.testing.expectEqual(@as(u32, 2), le32(bytes[12..16])); // chunk_count
    try std.testing.expectEqualSlices(u8, bytes[16..48], &model_hash);
    try std.testing.expectEqualSlices(u8, bytes[48..80], &engine_id);
    try std.testing.expectEqualSlices(u8, bytes[80..112], &head);
    try std.testing.expectEqual(@as(u64, 7), le64(bytes[112..120])); // record_count
    try std.testing.expectEqual(@as(u64, 11), le64(bytes[120..128])); // seq_min
    try std.testing.expectEqual(@as(u64, 42), le64(bytes[128..136])); // seq_max
    // Chunks, in seq order: seq u64 + dim x f32.
    try std.testing.expectEqual(@as(u64, 11), le64(bytes[136..144]));
    try std.testing.expectEqual(@as(f32, 0.5), @as(f32, @bitCast(le32(bytes[144..148]))));
    try std.testing.expectEqual(@as(f32, -0.25), @as(f32, @bitCast(le32(bytes[148..152]))));
    try std.testing.expectEqual(@as(u64, 42), le64(bytes[160..168]));
    // Footer: sha256 of everything before it.
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes[0 .. bytes.len - 32], &digest, .{});
    try std.testing.expectEqualSlices(u8, bytes[bytes.len - 32 ..], &digest);

    // Decode round trip: every field, byte for byte.
    const decoded = (try embed.decode(allocator, bytes)).?;
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 4), decoded.dim);
    try std.testing.expectEqual(@as(u32, 2), decoded.chunk_count);
    try std.testing.expectEqualSlices(u8, &decoded.model_hash, &model_hash);
    try std.testing.expectEqualSlices(u8, &decoded.engine_id, &engine_id);
    try std.testing.expectEqualSlices(u8, &decoded.head, &head);
    try std.testing.expectEqual(@as(u64, 7), decoded.record_count);
    try std.testing.expectEqual(@as(u64, 11), decoded.seq_min);
    try std.testing.expectEqual(@as(u64, 42), decoded.seq_max);
    try std.testing.expectEqualSlices(u64, decoded.seqs, seqs);
    try std.testing.expectEqualSlices(f32, decoded.vectors, vectors);
}

fn le32(b: []const u8) u32 {
    return b[0] | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn le64(b: []const u8) u64 {
    return le32(b[0..4]) | (@as(u64, le32(b[4..8])) << 32);
}

test "phase 8: ZDE1 decode — corruption is never trusted" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const head = blk: {
        var h: [32]u8 = undefined;
        @memset(&h, 7);
        break :blk h;
    };
    const seqs_desc = try allocator.alloc(u64, 2);
    seqs_desc[0] = 5;
    seqs_desc[1] = 3; // deliberately out of order
    const vectors = try allocator.alloc(f32, 8);
    @memset(vectors, 0.5);
    var store = embed.Store{
        .dim = 4,
        .chunk_count = 2,
        .model_hash = head,
        .engine_id = head,
        .head = head,
        .record_count = 2,
        .seq_min = 3,
        .seq_max = 5,
        .seqs = seqs_desc,
        .vectors = vectors,
        .allocator = allocator,
    };
    // A corrupt seq order is refused by the decoder (encode does not care;
    // the decoder is the boundary).
    const bad_order = try embed.encode(allocator, &store);
    defer allocator.free(bad_order);
    try std.testing.expect(embed.decode(allocator, bad_order) == error.BadSeqOrder);

    // The same content in seq order is a valid artifact.
    const seqs_ok = try allocator.alloc(u64, 2);
    seqs_ok[0] = 3;
    seqs_ok[1] = 5;
    store.seqs = seqs_ok;
    const bytes = try embed.encode(allocator, &store);
    defer allocator.free(bytes);

    // Truncated: shorter than header + footer.
    try std.testing.expect(embed.decode(allocator, bytes[0..embed.HeaderLen]) == error.Truncated);
    // Bad magic.
    const bad_magic = try allocator.dupe(u8, bytes);
    bad_magic[0] ^= 0xFF;
    try std.testing.expect(embed.decode(allocator, bad_magic) == error.BadMagic);
    allocator.free(bad_magic);
    // Bad version.
    const bad_version = try allocator.dupe(u8, bytes);
    bad_version[4] = 2;
    try std.testing.expect(embed.decode(allocator, bad_version) == error.BadVersion);
    allocator.free(bad_version);
    // Chunk body missing (between the minimum and the declared length).
    try std.testing.expect(embed.decode(allocator, bytes[0 .. bytes.len - 8]) == error.Truncated);
    // Bad footer.
    const bad_footer = try allocator.dupe(u8, bytes);
    bad_footer[bad_footer.len - 1] ^= 0xFF;
    try std.testing.expect(embed.decode(allocator, bad_footer) == error.BadFooter);
    allocator.free(bad_footer);
    // The valid artifact decodes.
    const ok = (try embed.decode(allocator, bytes)).?;
    defer ok.deinit();
    try std.testing.expectEqual(@as(u32, 2), ok.chunk_count);
}

// ---------------------------------------------------------------- rebuild

test "phase 8: rebuild is deterministic and visible-only" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase8-a");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();

    const engine = try FakeEngine.init(allocator, "fake-identity-v1");
    defer engine.deinit();

    const counts = try dstore.rebuildEmbeddings(allocator, f.journal, &v.visible, v.result, engine);
    // Visible entries only: 0, 3, 5 (private seq 1 and redacted seq 2
    // never enter a vector).
    try std.testing.expectEqual(@as(usize, 3), counts.chunk_count);
    // 136 (header) + 32 (footer) + 3 x (8 + 4 x 16), amortized per entry.
    try std.testing.expectEqual(@as(usize, (136 + 32 + 3 * (8 + 4 * 16)) / 3), counts.bytes_per_entry);

    const art1 = (try readArtifact(allocator, f.journal, dstore.EmbedFile)).?;
    defer allocator.free(art1);
    try std.testing.expectEqual(@as(usize, 136 + 32 + 3 * (8 + 4 * 16)), art1.len);

    // The artifact is a pure function of (verified log, model, identity):
    // delete and rebuild, byte for byte.
    try Dir.deleteFile(f.journal.dir, io, dstore.EmbedFile);
    try std.testing.expect((try readArtifact(allocator, f.journal, dstore.EmbedFile)) == null);
    _ = try dstore.rebuildEmbeddings(allocator, f.journal, &v.visible, v.result, engine);
    const art2 = (try readArtifact(allocator, f.journal, dstore.EmbedFile)).?;
    defer allocator.free(art2);
    try std.testing.expectEqualSlices(u8, art1, art2);

    const store = (try embed.decode(allocator, art1)).?;
    defer store.deinit();
    try std.testing.expectEqualSlices(u64, store.seqs, &[_]u64{ 0, 3, 5 });
    try std.testing.expectEqualSlices(u8, &store.head, &v.result.head);
    try std.testing.expectEqual(@as(u64, 6), store.record_count);
    try std.testing.expectEqual(@as(u64, 0), store.seq_min);
    try std.testing.expectEqual(@as(u64, 5), store.seq_max);
    // The pinned vectors: e0, e1, e2 in seq order.
    try std.testing.expectEqual(@as(f32, 1), store.vectors[0]);
    try std.testing.expectEqual(@as(f32, 1), store.vectors[16 + 1]);
    try std.testing.expectEqual(@as(f32, 1), store.vectors[32 + 2]);
}

test "phase 8: staleness — head, identity, and corruption are never served" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase8-b");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();

    const engine = try FakeEngine.init(allocator, "identity-a");
    defer engine.deinit();
    _ = try dstore.rebuildEmbeddings(allocator, f.journal, &v.visible, v.result, engine);

    // Fresh: the head matches.
    try std.testing.expect((try dstore.loadFreshEmbed(allocator, f.journal, v.result)) != null);

    // A head mismatch (one new record) means "no vectors".
    _ = try f.journal.appendRecord(allocator, .entry, 0, "a stale entry", &.{"stale"}, BASE + 25_200_000, 0, false);
    var v2 = try visibleOf(allocator, f.journal);
    defer v2.recs.deinit();
    defer v2.visible.deinit();
    try std.testing.expect(!std.mem.eql(u8, &v.result.head, &v2.result.head));
    try std.testing.expect((try dstore.loadFreshEmbed(allocator, f.journal, v2.result)) == null);

    // An identity change with the same head is equally unservable: the
    // artifact decodes and its head matches, but the engine binding no
    // longer holds (it was built under a different engine).
    const store = (try dstore.loadFreshEmbed(allocator, f.journal, v.result)).?;
    defer store.deinit();
    var s2 = store;
    var eid: [32]u8 = undefined;
    @memset(&eid, 0xAA);
    s2.engine_id = eid;
    const bytes = try embed.encode(allocator, &s2);
    defer allocator.free(bytes);
    try dstore.saveEmbed(f.journal, bytes);
    const other = (try dstore.loadFreshEmbed(allocator, f.journal, v.result)).?;
    defer other.deinit();
    try std.testing.expect(!embed.matchesEngine(&other, engine));

    // A corrupt artifact (footer) is the same: never served.
    const corrupt = try allocator.dupe(u8, bytes);
    corrupt[corrupt.len - 1] ^= 0xFF;
    try dstore.saveEmbed(f.journal, corrupt);
    allocator.free(corrupt);
    try std.testing.expect((try dstore.loadFreshEmbed(allocator, f.journal, v.result)) == null);
}

test "phase 8: derived status — the embed line classifies on the header alone" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase8-c");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();

    const engine = try FakeEngine.init(allocator, "status-identity");
    defer engine.deinit();

    // missing: no artifact yet.
    {
        const rep = try dstore.artifactStatus(allocator, f.journal, v.result);
        defer rep.deinit();
        const a = embedItem(rep.items);
        try std.testing.expect(a.state == .missing);
        try std.testing.expect(a.head == null);
        try std.testing.expect(a.dim == null);
    }

    // fresh: rebuilt under the fixture's head; every field echoes back.
    _ = try dstore.rebuildEmbeddings(allocator, f.journal, &v.visible, v.result, engine);
    {
        const rep = try dstore.artifactStatus(allocator, f.journal, v.result);
        defer rep.deinit();
        const a = embedItem(rep.items);
        try std.testing.expect(a.state == .fresh);
        try std.testing.expect(std.mem.eql(u8, &a.head.?, &v.result.head));
        try std.testing.expectEqual(a.dim.?, FakeEngine.Dim);
        try std.testing.expectEqual(@as(u64, 6), a.record_count.?);
        try std.testing.expect(std.mem.eql(u8, &a.model_hash.?, &engine.modelHash()));
        try std.testing.expect(std.mem.eql(u8, &a.engine_id.?, &engine.identity()));
    }

    // stale: the recorded head no longer matches. The verdict must come
    // from the header alone and echo the artifact's fields — the footer is
    // not even consulted (spec/semantic.md section 5).
    const art = (try readArtifact(allocator, f.journal, dstore.EmbedFile)).?;
    defer allocator.free(art);
    var stale = try allocator.dupe(u8, art);
    stale[80] ^= 0xFF; // the first byte of the head field
    try dstore.saveEmbed(f.journal, stale);
    allocator.free(stale);
    {
        const rep = try dstore.artifactStatus(allocator, f.journal, v.result);
        defer rep.deinit();
        const a = embedItem(rep.items);
        try std.testing.expect(a.state == .stale);
        var want_head = v.result.head;
        want_head[0] ^= 0xFF;
        try std.testing.expect(std.mem.eql(u8, &a.head.?, &want_head));
        try std.testing.expectEqual(a.dim.?, FakeEngine.Dim);
        try std.testing.expectEqual(@as(u64, 6), a.record_count.?);
        try std.testing.expect(std.mem.eql(u8, &a.model_hash.?, &engine.modelHash()));
        try std.testing.expect(std.mem.eql(u8, &a.engine_id.?, &engine.identity()));
    }

    // corrupt: the head matches but the footer byte is flipped — the line
    // carries no fields at all.
    var corrupt = try allocator.dupe(u8, art);
    corrupt[corrupt.len - 1] ^= 0xFF;
    try dstore.saveEmbed(f.journal, corrupt);
    allocator.free(corrupt);
    {
        const rep = try dstore.artifactStatus(allocator, f.journal, v.result);
        defer rep.deinit();
        const a = embedItem(rep.items);
        try std.testing.expect(a.state == .corrupt);
        try std.testing.expect(a.head == null);
        try std.testing.expect(a.dim == null);
    }
}

// ---------------------------------------------------------------- ranking

test "phase 8: keywordHits is exact on the fixture" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase8-c");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();

    // "anything"/"about" are question stopwords; "auth" hits seq 0 and 5,
    // tied, so seq asc.
    const kw = try embed.keywordHits(allocator, &v.visible, "anything about auth?");
    defer allocator.free(kw);
    try std.testing.expectEqual(@as(usize, 2), kw.len);
    try std.testing.expectEqual(@as(u64, 0), kw[0].seq);
    try std.testing.expectEqual(@as(f64, 1), kw[0].score);
    try std.testing.expectEqual(@as(u64, 5), kw[1].seq);
    try std.testing.expectEqual(@as(f64, 1), kw[1].score);

    // "walk"/"my"/"did"/"when" are stopwords or non-matching; only "dog"
    // hits, once.
    const dog = try embed.keywordHits(allocator, &v.visible, "when did I walk my dog?");
    defer allocator.free(dog);
    try std.testing.expectEqual(@as(usize, 1), dog.len);
    try std.testing.expectEqual(@as(u64, 3), dog[0].seq);
    try std.testing.expectEqual(@as(f64, 1), dog[0].score);

    // No word of two or more letters: no hits, not an error.
    const none = try embed.keywordHits(allocator, &v.visible, "a i ?");
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "phase 8: RRF fusion is exact (hand-computed)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // kw=[7,3], vec=[7,3]: 7 -> 1/61 + 1/61, 3 -> 1/62 + 1/62 = 1/31.
    const kw1 = [_]u64{ 7, 3 };
    const fused1 = try embed.rrfFusion(allocator, &kw1, &kw1);
    defer allocator.free(fused1);
    try std.testing.expectEqual(@as(usize, 2), fused1.len);
    try std.testing.expectEqual(@as(u64, 7), fused1[0].seq);
    try std.testing.expectEqual(@as(f64, 2.0 / 61.0), fused1[0].score);
    try std.testing.expectEqual(@as(u64, 3), fused1[1].seq);
    try std.testing.expectEqual(@as(f64, 1.0 / 31.0), fused1[1].score);

    // kw=[5], vec=[3]: a perfect tie (1/61 each) resolves by seq asc.
    const a = [_]u64{5};
    const b = [_]u64{3};
    const fused2 = try embed.rrfFusion(allocator, &a, &b);
    defer allocator.free(fused2);
    try std.testing.expectEqual(@as(usize, 2), fused2.len);
    try std.testing.expectEqual(@as(u64, 3), fused2[0].seq);
    try std.testing.expectEqual(@as(u64, 5), fused2[1].seq);
    try std.testing.expectEqual(fused2[0].score, fused2[1].score);

    // kw=[5,0,3], vec=[3,0,5]: 3 and 5 tie at 1/61 + 1/63 (= 124/3843),
    // which beats 0's 1/62 + 1/62 (= 1/31); the tie takes seq asc. The
    // fusion order differs from both input orders.
    const kw3 = [_]u64{ 5, 0, 3 };
    const vec3 = [_]u64{ 3, 0, 5 };
    const fused3 = try embed.rrfFusion(allocator, &kw3, &vec3);
    defer allocator.free(fused3);
    try std.testing.expectEqual(@as(usize, 3), fused3.len);
    try std.testing.expectEqual(@as(u64, 3), fused3[0].seq);
    try std.testing.expectEqual(@as(u64, 5), fused3[1].seq);
    try std.testing.expectEqual(@as(u64, 0), fused3[2].seq);
    try std.testing.expectEqual(@as(f64, 1.0 / 61.0 + 1.0 / 63.0), fused3[0].score);
    try std.testing.expectEqual(fused3[0].score, fused3[1].score);
    try std.testing.expectEqual(@as(f64, 1.0 / 31.0), fused3[2].score);

    // A list-only entry still appears: kw=[9], vec=[].
    const only = [_]u64{9};
    const fused4 = try embed.rrfFusion(allocator, &only, &[_]u64{});
    defer allocator.free(fused4);
    try std.testing.expectEqual(@as(usize, 1), fused4.len);
    try std.testing.expectEqual(@as(f64, 1.0 / 61.0), fused4[0].score);
}

test "phase 8: cosine top-N — exact scores, ties by seq, cap" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const seqs = [_]u64{ 2, 1 }; // storage order is not seq order
    const vectors = [_]f32{ 1, 0, 0, 1 }; // seq 2 -> e0, seq 1 -> e1
    const q = [_]f32{ 0.5, 0.5 };

    // Tied dot products (0.5 each): seq asc.
    const all = try embed.cosineTopN(allocator, &seqs, &vectors, 2, &q, 10);
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(@as(u64, 1), all[0].seq);
    try std.testing.expectEqual(@as(f64, 0.5), all[0].score);
    try std.testing.expectEqual(@as(u64, 2), all[1].seq);

    // A strict order, capped to one.
    const q2 = [_]f32{ 0.9, 0.1 };
    const top = try embed.cosineTopN(allocator, &seqs, &vectors, 2, &q2, 1);
    defer allocator.free(top);
    try std.testing.expectEqual(@as(usize, 1), top.len);
    try std.testing.expectEqual(@as(u64, 2), top[0].seq);
    // The doc vector is (1, 0), so the score is exactly the f64 lift of the
    // f32 query component (0.9 does not round-trip: f32(0.9) < 0.9).
    try std.testing.expectEqual(@as(f64, @floatCast(@as(f32, 0.9))), top[0].score);
}

// ---------------------------------------------------------------- context pack

test "phase 8: contextPack — the hybrid list is the fusion order" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase8-d");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();

    const range = view.DayRange{ .start = D0, .end = D0 + 1 };
    const question = "auth";

    // Keyword-only (the Phase 7 bytes, unchanged by the new parameter).
    const pack_kw = try dstore.contextPack(allocator, f.journal, &v.visible, v.result, question, range, true, null);
    defer allocator.free(pack_kw);
    try std.testing.expect(indexOf(pack_kw, "# 2 matches for \"auth\"\n") != null);

    // Build the artifact and take the hybrid path.
    const engine = try FakeEngine.init(allocator, "pack-identity");
    defer engine.deinit();
    _ = try dstore.rebuildEmbeddings(allocator, f.journal, &v.visible, v.result, engine);
    const store = (try dstore.loadFreshEmbed(allocator, f.journal, v.result)).?;
    defer store.deinit();
    const qv = try engine.embed(allocator, &.{question}, .query);
    defer {
        for (qv) |vec| allocator.free(vec);
        allocator.free(qv);
    }
    const hybrid = dstore.Hybrid{ .store = &store, .query = qv[0] };
    const pack_hyb = try dstore.contextPack(allocator, f.journal, &v.visible, v.result, question, range, true, hybrid);
    defer allocator.free(pack_hyb);

    // The hybrid list: the vector order is [5, 3, 0] (e2 closest to the
    // query), the keyword order is [0, 5]; the fusion is
    //   5 -> 1/62 + 1/61,  0 -> 1/61 + 1/63,  3 -> 1/62
    // which differs from both: [5, 0, 3].
    try std.testing.expect(!std.mem.eql(u8, pack_kw, pack_hyb));
    const hyb_head = "# 3 matches for \"auth\"\n";
    const at = indexOf(pack_hyb, hyb_head) orelse std.debug.panic("hybrid pack has no matches section", .{});
    const matches = pack_hyb[at..];
    const pos5 = indexOf(matches, "shipped the auth token fix") orelse std.debug.panic("no seq 5 in hybrid matches", .{});
    const pos0 = indexOf(matches, "shipped the auth fix\n") orelse std.debug.panic("no seq 0 in hybrid matches", .{});
    const pos3 = indexOf(matches, "walked the dog\n") orelse std.debug.panic("no seq 3 in hybrid matches", .{});
    try std.testing.expect(pos5 < pos0);
    try std.testing.expect(pos0 < pos3);
}
