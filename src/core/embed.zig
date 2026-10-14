//! Semantic layer, core side (spec/semantic.md sections 3-6): the engine
//! interface, the ZDE1 vector artifact, Phase 7 keyword retrieval as a
//! ranked list, and the hybrid fusion. Engine-agnostic by design: a
//! concrete engine implements the vtable (the llama.cpp engine lives in
//! the CLI layer, `src/embed`; tests supply a deterministic fake). Nothing
//! in this module loads a model, links an engine library, or prints.

const std = @import("std");
const records = @import("records.zig");
const tokens = @import("tokens.zig");
const view = @import("view.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

const Allocator = std.mem.Allocator;

pub const Engine = struct {
    vtable: *const VTable,
    data: ?*anyopaque,

    /// How the text is framed before it reaches the model (spec/semantic.md
    /// section 4): the document side for entries, the query side for
    /// questions. The framing is part of the frozen embedding input.
    pub const Kind = enum { query, document };

    pub const VTable = struct {
        /// Embeds `texts`, one L2-normalized vector per text, in order.
        /// The engine owns its model state and batches internally; the
        /// caller frees each vector, then the slice of vectors.
        embed: *const fn (data: ?*anyopaque, allocator: Allocator, texts: []const []const u8, kind: Kind) EmbedError![][]f32,
        /// 32-byte identity: sha256 of "<model sha256, lowercase hex> | <engine id string>".
        identity: *const fn (data: ?*anyopaque) [32]u8,
        /// sha256 of the model file the engine loaded (pinned on load).
        modelHash: *const fn (data: ?*anyopaque) [32]u8,
        /// Vector dimension.
        dim: *const fn (data: ?*anyopaque) u32,
        /// Releases the model state. Owned by the caller of `create`.
        deinit: *const fn (data: ?*anyopaque) void,
    };

    pub fn embed(self: Engine, allocator: Allocator, texts: []const []const u8, kind: Kind) EmbedError![][]f32 {
        return self.vtable.embed(self.data, allocator, texts, kind);
    }
    pub fn identity(self: Engine) [32]u8 {
        return self.vtable.identity(self.data);
    }
    pub fn modelHash(self: Engine) [32]u8 {
        return self.vtable.modelHash(self.data);
    }
    pub fn dim(self: Engine) u32 {
        return self.vtable.dim(self.data);
    }
    pub fn deinit(self: Engine) void {
        self.vtable.deinit(self.data);
    }
};

/// Every error the embedding surface can produce (spec/semantic.md
/// sections 2-4). Model problems are actionable: the message must name the
/// path or the pinned model, never a raw engine failure.
pub const EmbedError = Allocator.Error || error{
    /// This build has no engine (`zig build --no-embed`).
    EngineUnavailable,
    /// The model file is not at the resolved path.
    ModelNotFound,
    /// The model file's size or sha256 does not match the pinned model.
    ModelMismatch,
    /// The engine refused to load the model.
    ModelLoadFailed,
    /// The engine context could not be initialized.
    ContextInitFailed,
    /// A text tokenizes past the engine's context.
    SequenceTooLong,
    /// The engine failed to decode a batch.
    DecodeFailed,
};

// ---------------------------------------------------------------- ZDE1

pub const Magic = [_]u8{ 'Z', 'D', 'E', '1' };
pub const FormatVersion: u8 = 1;

// Little-endian integer I/O. ZDE1 is the project's only little-endian
// format (records.zig's helpers are big-endian), so its helpers live here.
fn leWriteU32(buf: []u8, value: u32) void {
    buf[0] = @intCast(value & 0xFF);
    buf[1] = @intCast((value >> 8) & 0xFF);
    buf[2] = @intCast((value >> 16) & 0xFF);
    buf[3] = @intCast(value >> 24);
}

fn leWriteU64(buf: []u8, value: u64) void {
    leWriteU32(buf[0..4], @intCast(value & 0xFFFFFFFF));
    leWriteU32(buf[4..8], @intCast(value >> 32));
}

fn leReadU32(bytes: []const u8) u32 {
    return bytes[0] | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn leReadU64(bytes: []const u8) u64 {
    return leReadU32(bytes[0..4]) | (@as(u64, leReadU32(bytes[4..8])) << 32);
}

/// Copies a 32-byte slice into an array (slices do not coerce to arrays).
fn digest32(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    @memcpy(&out, bytes);
    return out;
}

/// Header: magic(4) version(1) flags(1) pad(2) dim(4) chunk_count(4)
/// model_hash(32) engine_id(32) head(32) record_count(8) seq_min(8)
/// seq_max(8). All integers little-endian.
pub const HeaderLen: usize = 136;
pub const FooterLen: usize = records.DigestLen;
pub const MinLen: usize = HeaderLen + FooterLen;

/// A decoded ZDE1 artifact (spec/semantic.md section 5). The vectors are
/// pure functions of (verified log, model bytes, engine identity, frozen
/// batch configuration): never verified or anchored, always rebuildable.
pub const Store = struct {
    dim: u32,
    chunk_count: u32,
    model_hash: [32]u8,
    engine_id: [32]u8,
    head: [records.DigestLen]u8,
    record_count: u64,
    seq_min: u64,
    seq_max: u64,
    /// In ascending seq order; len == chunk_count.
    seqs: []u64,
    /// chunk_count x dim, in `seqs` order.
    vectors: []f32,
    allocator: Allocator,

    /// Frees `seqs` and `vectors` (by value: the struct is Copyable, and
    /// the slices outlive any capture that is const).
    pub fn deinit(self: Store) void {
        self.allocator.free(self.seqs);
        self.allocator.free(self.vectors);
    }
};

pub const DecodeError = Allocator.Error || error{
    Truncated,
    BadMagic,
    BadVersion,
    BadSeqOrder,
    BadFooter,
};

/// Serializes a store to a complete ZDE1 document (header, chunks in seq
/// order, trailing sha256 of everything before it). Integers are
/// little-endian on every platform.
pub fn encode(allocator: Allocator, s: *const Store) Allocator.Error![]u8 {
    const n = s.chunk_count;
    if (s.seqs.len != n or s.vectors.len != n * s.dim) {
        std.debug.panic("embed encode: chunk_count disagrees with the slices", .{});
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var u32buf: [4]u8 = undefined;
    var u64buf: [8]u8 = undefined;
    for (Magic) |m| try out.append(allocator, m);
    try out.append(allocator, FormatVersion);
    try out.append(allocator, 0); // flags
    try out.appendSlice(allocator, &.{ 0, 0 }); // pad
    leWriteU32(&u32buf, s.dim);
    try out.appendSlice(allocator, &u32buf);
    leWriteU32(&u32buf, n);
    try out.appendSlice(allocator, &u32buf);
    try out.appendSlice(allocator, &s.model_hash);
    try out.appendSlice(allocator, &s.engine_id);
    try out.appendSlice(allocator, &s.head);
    leWriteU64(&u64buf, s.record_count);
    try out.appendSlice(allocator, &u64buf);
    leWriteU64(&u64buf, s.seq_min);
    try out.appendSlice(allocator, &u64buf);
    leWriteU64(&u64buf, s.seq_max);
    try out.appendSlice(allocator, &u64buf);
    // Chunks in seq order: seq u64 + its dim x f32, interleaved.
    for (s.seqs, 0..) |seq, i| {
        leWriteU64(&u64buf, seq);
        try out.appendSlice(allocator, &u64buf);
        for (s.vectors[i * s.dim .. (i + 1) * s.dim]) |v| {
            leWriteU32(&u32buf, @bitCast(v));
            try out.appendSlice(allocator, &u32buf);
        }
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(out.items, &digest, .{});
    try out.appendSlice(allocator, &digest);
    return out.toOwnedSlice(allocator);
}

/// Parses a complete ZDE1 document. The footer hash is checked before
/// anything is trusted; a failure is indistinguishable from a stale
/// artifact at the call sites (both mean "no vectors").
pub fn decode(allocator: Allocator, bytes: []const u8) DecodeError!?Store {
    if (bytes.len < MinLen) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &Magic)) return error.BadMagic;
    if (bytes[4] != FormatVersion) return error.BadVersion;
    const dim = leReadU32(bytes[8..12]);
    const n = leReadU32(bytes[12..16]);
    // Overflow-safe expected length: a corrupt header must not be able to
    // overflow the usize arithmetic.
    const per_chunk: u64 = 8 + @as(u64, dim) * 4; // dim < 2^32, no overflow
    if (n != 0 and per_chunk > (std.math.maxInt(u64) - MinLen) / n) return error.Truncated;
    const want: u64 = @as(u64, MinLen) + @as(u64, n) * per_chunk;
    if (want > bytes.len) return error.Truncated;

    var store = Store{
        .dim = dim,
        .chunk_count = n,
        .model_hash = digest32(bytes[16..48]),
        .engine_id = digest32(bytes[48..80]),
        .head = digest32(bytes[80..112]),
        .record_count = leReadU64(bytes[112..120]),
        .seq_min = leReadU64(bytes[120..128]),
        .seq_max = leReadU64(bytes[128..136]),
        .seqs = try allocator.alloc(u64, @intCast(n)),
        .vectors = try allocator.alloc(f32, @as(usize, n) * @as(usize, dim)),
        .allocator = allocator,
    };
    errdefer store.deinit();

    var off: usize = HeaderLen;
    var prev: u64 = 0;
    for (store.seqs, 0..) |*seq, i| {
        seq.* = leReadU64(bytes[off .. off + 8]);
        if (seq.* < prev) return error.BadSeqOrder;
        prev = seq.*;
        off += 8;
        const chunk = store.vectors[i * dim .. (i + 1) * dim];
        for (chunk) |*v| {
            v.* = @bitCast(leReadU32(bytes[off .. off + 4]));
            off += 4;
        }
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[0 .. bytes.len - FooterLen], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[bytes.len - FooterLen ..])) return error.BadFooter;
    return store;
}

/// The ZDE1 header fields: what `derived status` needs to classify an
/// artifact (spec/semantic.md section 5) without trusting the document —
/// no chunk data, no footer.
pub const Header = struct {
    dim: u32,
    chunk_count: u32,
    model_hash: [32]u8,
    engine_id: [32]u8,
    head: [records.DigestLen]u8,
    record_count: u64,
    seq_min: u64,
    seq_max: u64,
};

/// Parses the ZDE1 header alone: magic, version, and the field block that
/// follows. No footer check, no allocation — an artifact whose head
/// decodes but no longer matches must be reported stale without trusting
/// the rest of the document. Null when the bytes do not hold a well-formed
/// header.
pub fn decodeHeader(bytes: []const u8) ?Header {
    if (bytes.len < HeaderLen) return null;
    if (!std.mem.eql(u8, bytes[0..4], &Magic)) return null;
    if (bytes[4] != FormatVersion) return null;
    return .{
        .dim = leReadU32(bytes[8..12]),
        .chunk_count = leReadU32(bytes[12..16]),
        .model_hash = digest32(bytes[16..48]),
        .engine_id = digest32(bytes[48..80]),
        .head = digest32(bytes[80..112]),
        .record_count = leReadU64(bytes[112..120]),
        .seq_min = leReadU64(bytes[120..128]),
        .seq_max = leReadU64(bytes[128..136]),
    };
}

/// True when `store` was built under `engine`'s model and identity
/// (spec/semantic.md section 5): an artifact from another model or engine
/// is stale and never served. The check happens where a loaded engine
/// exists — the read path loads one only after the head check passes.
pub fn matchesEngine(store: *const Store, engine: Engine) bool {
    return std.mem.eql(u8, &store.model_hash, &engine.modelHash()) and
        std.mem.eql(u8, &store.engine_id, &engine.identity());
}

// ---------------------------------------------------------------- ranking

/// One ranked hit: the entry's seq and its mode-specific score.
pub const RankHit = struct {
    seq: u64,
    score: f64,
};

fn hitLessThan(_: void, a: RankHit, b: RankHit) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.seq < b.seq;
}

/// Cosine top-N (the vectors are L2-normalized, so a dot product; the
/// accumulation is f64 in fixed order, so the ranking is bitwise
/// deterministic). Ties: seq asc. `vectors` is `seqs.len x dim`.
pub fn cosineTopN(
    allocator: Allocator,
    seqs: []const u64,
    vectors: []const f32,
    dim: u32,
    query: []const f32,
    n: usize,
) Allocator.Error![]RankHit {
    if (vectors.len != seqs.len * dim or query.len != dim) {
        std.debug.panic("cosineTopN: slice sizes disagree with dim", .{});
    }
    var hits = std.ArrayList(RankHit).empty;
    errdefer hits.deinit(allocator);
    for (seqs, 0..) |seq, i| {
        const v = vectors[i * dim .. (i + 1) * dim];
        var dot: f64 = 0;
        for (v, query) |a, b| dot += @as(f64, @floatCast(a)) * @as(f64, @floatCast(b));
        try hits.append(allocator, .{ .seq = seq, .score = dot });
    }
    std.mem.sort(RankHit, hits.items, {}, hitLessThan);
    if (n < hits.items.len) {
        const trimmed = try allocator.alloc(RankHit, n);
        @memcpy(trimmed, hits.items[0..n]);
        hits.deinit(allocator);
        return trimmed;
    }
    return hits.toOwnedSlice(allocator);
}

/// Reciprocal rank fusion of the keyword and vector lists
/// (spec/semantic.md section 6): score(s) = sum over lists of 1 / (60 +
/// rank), ranks 1-based; an entry absent from a list gets no term. Ties:
/// seq asc.
pub const RrfK: f64 = 60;

/// Adds one list's terms to the fusion scores (0.17 has no nested
/// functions, so the helper takes its state explicitly).
fn addRrfTerms(scores: *std.array_hash_map.Auto(u64, f64), allocator: Allocator, list: []const u64) Allocator.Error!void {
    for (list, 0..) |seq, rank| {
        const term: f64 = 1 / (RrfK + @as(f64, @floatFromInt(@as(u64, rank) + 1)));
        const res = scores.getOrPut(allocator, seq) catch return error.OutOfMemory;
        if (res.found_existing) {
            res.value_ptr.* += term;
        } else {
            res.value_ptr.* = term;
        }
    }
}

pub fn rrfFusion(allocator: Allocator, keyword: []const u64, vector: []const u64) Allocator.Error![]RankHit {
    var scores = std.array_hash_map.Auto(u64, f64).empty;
    errdefer scores.deinit(allocator);
    try addRrfTerms(&scores, allocator, keyword);
    try addRrfTerms(&scores, allocator, vector);
    var hits = std.ArrayList(RankHit).empty;
    errdefer hits.deinit(allocator);
    for (scores.keys(), scores.values()) |seq, score| {
        try hits.append(allocator, .{ .seq = seq, .score = score });
    }
    std.mem.sort(RankHit, hits.items, {}, hitLessThan);
    return hits.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- keyword

/// Phase 7 token retrieval as a ranked list (spec/semantic.md section 6):
/// the question's words — shared tokenizer, consecutive duplicates and
/// sub-2-letter runs removed, question stopwords dropped, lowercased,
/// deduplicated — counted per visible entry as distinct token hits
/// (case-insensitive, whole tokens only). Entries with at least one hit,
/// in (hits desc, seq asc) order; the score is the hit count.
pub const KeywordError = Allocator.Error;

pub fn keywordHits(allocator: Allocator, visible: *const view.Visible, question: []const u8) KeywordError![]RankHit {
    // Question words, exactly as dstore.retrieve processes them.
    const sp = try tokens.spans(allocator, question);
    defer allocator.free(sp);
    var qwords = std.ArrayList([]const u8).empty;
    errdefer {
        for (qwords.items) |w| allocator.free(w);
        allocator.free(qwords.items);
    }
    var i: usize = 0;
    while (i < sp.len) {
        if (i > 0 and std.mem.eql(u8, tokens.token(question, sp[i - 1]), tokens.token(question, sp[i]))) {
            i += 1;
            continue;
        }
        if (sp[i].end - sp[i].start < 2) {
            i += 1;
            continue;
        }
        if (tokens.isStopword(question, sp[i], &tokens.QuestionStopwords)) {
            i += 1;
            continue;
        }
        const w = try tokens.lowercase(allocator, question, sp[i]);
        errdefer allocator.free(w);
        var dup = false;
        for (qwords.items) |have| {
            if (std.mem.eql(u8, have, w)) {
                dup = true;
                break;
            }
        }
        if (!dup) try qwords.append(allocator, w);
        i += 1;
    }
    if (qwords.items.len == 0) return try allocator.alloc(RankHit, 0);

    var hits = std.ArrayList(RankHit).empty;
    errdefer hits.deinit(allocator);
    for (visible.entries) |e| {
        if (e.redacted) continue;
        const esp = try tokens.spans(allocator, e.text);
        defer allocator.free(esp);
        var count: u64 = 0;
        for (qwords.items) |w| {
            for (esp) |s| {
                if (std.ascii.eqlIgnoreCase(tokens.token(e.text, s), w)) {
                    count += 1;
                    break;
                }
            }
        }
        if (count > 0) try hits.append(allocator, .{ .seq = e.seq, .score = @as(f64, @floatFromInt(count)) });
    }
    std.mem.sort(RankHit, hits.items, {}, hitLessThan);
    return hits.toOwnedSlice(allocator);
}
