//! Phase 7 gate: the derived layer (spec/derived.md section 8) on a
//! journal over in-memory I/O.
//!
//!   - Rebuild determinism: deleting derived/ and profile.md and re-
//!     reading yields byte-identical index, profile, and pack.
//!   - Staleness: an append plus a redaction moves the head; the next
//!     read regenerates, and the digest reflects the redaction.
//!   - Oracle agreement: indexed retrieval returns exactly the entries a
//!     brute-force token scan returns, with and without a date scope.
//!   - Migration: a hand-written profile.md moves verbatim into notes.md
//!     (blank-line separated when notes exist), a versioned profile is
//!     written, and a second run changes nothing.
//!   - Status and rebuild: artifact states (fresh/stale/corrupt) and the
//!     forced rebuild; notes.md is never rewritten.
//!   - The MCP posture: a persist=false pack computes everything in
//!     memory and writes nothing.

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const journal_mod = core.journal;
const view = core.view;
const tokens = core.tokens;
const derived = core.derived;
const dstore = core.dstore;

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

/// The shared fixture: five records, one UTC day (2026-01-01).
///   seq 0: [work] "shipped the auth fix"          01:00
///   seq 1: private "PRIVATE-P7-MARKER-7a1e"       02:00
///   seq 2: "sensitive meeting notes"              03:00 (redacted below)
///   seq 3: "walked the dog"                       04:00
///   seq 4: redaction of seq 2                     05:00
fn fillFixture(allocator: Allocator, journal: *const journal_mod.Journal) !void {
    _ = try journal.appendRecord(allocator, .entry, 0, "shipped the auth fix", &.{"work"}, BASE + 3_600_000, 0, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "PRIVATE-P7-MARKER-7a1e", &.{"priv"}, BASE + 7_200_000, 0, true);
    _ = try journal.appendRecord(allocator, .entry, 0, "sensitive meeting notes", &.{}, BASE + 10_800_000, 0, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "walked the dog", &.{}, BASE + 14_400_000, 0, false);
    _ = try journal.redact(allocator, 2, BASE + 18_000_000, 0);
}

/// The verified records and the entries the view shows (the pack's input).
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

/// One artifact file of the journal directory, or null when absent.
fn readArtifact(allocator: Allocator, journal: *const journal_mod.Journal, name: []const u8) !?[]u8 {
    return journal.readJournalFile(allocator, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

// ---------------------------------------------------------------- oracle

/// Lowercases `text` into `list` (one append).
fn addLower(allocator: Allocator, list: *std.ArrayList([]const u8), text: []const u8) !void {
    var copy = std.ArrayList(u8).empty;
    errdefer copy.deinit(allocator);
    for (text) |c| try copy.append(allocator, std.ascii.toLower(c));
    try list.append(allocator, try copy.toOwnedSlice(allocator));
}

/// The brute-force token scan (spec/derived.md section 8): a visible
/// entry matches when any question word (tokenizer, stopwords removed,
/// lowercased) is among its words (tags as whole tokens plus text
/// tokens, mirroring `derived.buildIndex`). Scoped to `range` when set.
fn oracleSeqs(
    allocator: Allocator,
    visible: *const view.Visible,
    question: []const u8,
    range: ?view.DayRange,
) ![]u64 {
    var out = std.ArrayList(u64).empty;
    errdefer out.deinit(allocator);

    var qwords = std.ArrayList([]const u8).empty;
    errdefer {
        for (qwords.items) |w| allocator.free(w);
        allocator.free(qwords.items);
    }
    const sp = try tokens.spans(allocator, question);
    defer allocator.free(sp);
    for (sp) |s| {
        if (s.end - s.start < 2) continue;
        if (tokens.isStopword(question, s, &tokens.QuestionStopwords)) continue;
        const w = try tokens.lowercase(allocator, question, s);
        var dup = false;
        for (qwords.items) |q| {
            if (std.mem.eql(u8, q, w)) {
                dup = true;
                break;
            }
        }
        if (!dup) try qwords.append(allocator, w);
    }

    for (visible.entries) |e| {
        if (e.redacted) continue;
        if (range) |r| {
            if (e.day < r.start or e.day >= r.end) continue;
        }
        var etoks = std.ArrayList([]const u8).empty;
        defer {
            for (etoks.items) |t| allocator.free(t);
            allocator.free(etoks.items);
        }
        for (e.tags) |tag| {
            if (tag.len >= 2 and tag.len <= derived.MaxNameLen) try addLower(allocator, &etoks, tag);
        }
        const esp = try tokens.spans(allocator, e.text);
        defer allocator.free(esp);
        for (esp) |s| {
            if (s.end - s.start >= 2) try addLower(allocator, &etoks, tokens.token(e.text, s));
        }
        var hit = false;
        for (qwords.items) |w| {
            for (etoks.items) |t| {
                if (std.mem.eql(u8, t, w)) {
                    hit = true;
                    break;
                }
            }
            if (hit) break;
        }
        if (hit) try out.append(allocator, e.seq);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- tests

test "phase 7: rebuild is deterministic after deletion" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase7-a");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    const range = view.DayRange{ .start = D0, .end = D0 + 1 };
    const question = "anything about auth?";

    var v1 = try visibleOf(allocator, f.journal);
    const pack1 = try dstore.contextPack(allocator, f.journal, &v1.visible, v1.result, question, range, true, null);
    defer allocator.free(pack1);
    const index1 = (try readArtifact(allocator, f.journal, dstore.IndexFile)).?;
    defer allocator.free(index1);
    const profile1 = (try readArtifact(allocator, f.journal, dstore.ProfileFile)).?;
    defer allocator.free(profile1);
    v1.recs.deinit();
    v1.visible.deinit();

    // The cache is expendable: delete it and re-read.
    try Dir.deleteTree(f.journal.dir, io, dstore.DerivedDir);
    try Dir.deleteFile(f.journal.dir, io, dstore.ProfileFile);
    try std.testing.expect((try readArtifact(allocator, f.journal, dstore.IndexFile)) == null);
    try std.testing.expect((try readArtifact(allocator, f.journal, dstore.ProfileFile)) == null);

    var v2 = try visibleOf(allocator, f.journal);
    defer v2.recs.deinit();
    defer v2.visible.deinit();
    const pack2 = try dstore.contextPack(allocator, f.journal, &v2.visible, v2.result, question, range, true, null);
    defer allocator.free(pack2);
    const index2 = (try readArtifact(allocator, f.journal, dstore.IndexFile)).?;
    defer allocator.free(index2);
    const profile2 = (try readArtifact(allocator, f.journal, dstore.ProfileFile)).?;
    defer allocator.free(profile2);

    // Byte-identical, all three: the artifacts are pure functions of the
    // verified log.
    try std.testing.expectEqualSlices(u8, index1, index2);
    try std.testing.expectEqualSlices(u8, profile1, profile2);
    try std.testing.expectEqualSlices(u8, pack1, pack2);
}

test "phase 7: staleness — append and redact regenerate the artifacts" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase7-b");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    const range = view.DayRange{ .start = D0, .end = D0 + 1 };
    var v1 = try visibleOf(allocator, f.journal);
    const digest1 = try dstore.digestOrRebuild(allocator, f.journal, &v1.visible, range, v1.result);
    defer allocator.free(digest1);
    v1.recs.deinit();
    v1.visible.deinit();

    // Move the head: one new entry (00:15, same day), then redact the dog
    // walk (06:00). Timestamps stay increasing and within the fixture day.
    _ = try f.journal.appendRecord(allocator, .entry, 0, "new Berlin meeting", &.{"work"}, BASE + 900_000, 0, false);
    _ = try f.journal.redact(allocator, 3, BASE + 21_600_000, 0);

    var v2 = try visibleOf(allocator, f.journal);
    defer v2.recs.deinit();
    defer v2.visible.deinit();
    try std.testing.expect(!std.mem.eql(u8, &v1.result.head, &v2.result.head));
    // The stored digest is stale (old head): the next read regenerates it.
    const stale = try dstore.loadFreshDigest(allocator, f.journal, range, v2.result);
    try std.testing.expect(stale == null);
    const digest2 = try dstore.digestOrRebuild(allocator, f.journal, &v2.visible, range, v2.result);
    defer allocator.free(digest2);
    // Two redactions (seq 2, seq 3), four visible entries, and the new
    // entry's tag pushes work to 2.
    try std.testing.expect(contains(digest2, "4 entries (2 redacted)"));
    try std.testing.expect(contains(digest2, "tags: work 2"));
    try std.testing.expect(!std.mem.eql(u8, digest1, digest2));

    // The profile follows on its next persisting read.
    const prof = try dstore.profileWithNotes(allocator, f.journal, &v2.visible, v2.result);
    defer allocator.free(prof);
    try std.testing.expect(contains(prof, "4 entries, 2026-01-01..2026-01-01 (2 redacted)"));
    // No notes.md in this journal: the one-line note marks the boundary.
    try std.testing.expect(contains(prof, "# notes"));
    try std.testing.expect(contains(prof, "(no notes)"));
}

test "phase 7: indexed retrieval agrees with the brute-force oracle" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase7-c");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();
    const idx = try derived.buildIndex(allocator, &v.visible, v.result.head, v.result.record_count);
    defer idx.deinit();

    const scope = view.DayRange{ .start = D0, .end = D0 + 1 };
    const questions = [_][]const u8{
        "anything about auth?", // text token -> seq 0
        "did the dog walk?", // "dog" -> seq 3; "walk" matches nothing
        "tell me about the work tag", // tag token -> seq 0
        "what did I ship?", // all stopwords/short/absent -> nothing
        "Berlin", // absent -> nothing
    };
    const scopes = [_]?view.DayRange{ scope, null };
    for (questions) |q| {
        for (scopes) |r| {
            const got = try dstore.retrieve(allocator, &v.visible, &idx, q, r, v.result.record_count);
            defer allocator.free(got);
            const want = try oracleSeqs(allocator, &v.visible, q, r);
            defer allocator.free(want);
            try std.testing.expectEqual(@as(usize, want.len), got.len);
            for (got, want) |m, s| try std.testing.expectEqual(s, m.seq);
        }
    }

    // Known answers, not just agreement: the fixture is small enough to
    // pin the oracle itself.
    const auth = try oracleSeqs(allocator, &v.visible, "anything about auth?", scope);
    defer allocator.free(auth);
    try std.testing.expectEqualSlices(u64, &[_]u64{0}, auth);
    const dog = try oracleSeqs(allocator, &v.visible, "did the dog walk?", null);
    defer allocator.free(dog);
    try std.testing.expectEqualSlices(u64, &[_]u64{3}, dog);
}

test "phase 7: legacy profile migrates to notes exactly once" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase7-d");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    const legacy = "I am a hand-written profile.\nLine two, with a Zephyr mention.\n";
    const dir = f.journal.dir;
    try writeArtifact(dir, io, dstore.ProfileFile, legacy);

    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();

    // First persisting read: the legacy text moves verbatim to notes.md,
    // the derived profile takes profile.md's place, and the presentation
    // carries both under the machine/user boundary.
    const out1 = try dstore.profileWithNotes(allocator, f.journal, &v.visible, v.result);
    defer allocator.free(out1);
    const notes1 = (try readArtifact(allocator, f.journal, dstore.NotesFile)).?;
    defer allocator.free(notes1);
    try std.testing.expectEqualStrings(legacy, notes1);
    const profile1 = (try readArtifact(allocator, f.journal, dstore.ProfileFile)).?;
    defer allocator.free(profile1);
    try std.testing.expect(std.mem.startsWith(u8, profile1, dstore.ProfileHeader));
    try std.testing.expect(contains(out1, "# notes"));
    try std.testing.expect(contains(out1, "I am a hand-written profile."));
    try std.testing.expect(contains(out1, "Line two, with a Zephyr mention."));

    // The user then extends their notes; a second run must change nothing.
    const user_note = "I like tea.\n";
    try writeArtifact(dir, io, dstore.NotesFile, try allocator.print("{s}{s}", .{ legacy, user_note }));
    const out2 = try dstore.profileWithNotes(allocator, f.journal, &v.visible, v.result);
    defer allocator.free(out2);
    const notes2 = (try readArtifact(allocator, f.journal, dstore.NotesFile)).?;
    defer allocator.free(notes2);
    const profile2 = (try readArtifact(allocator, f.journal, dstore.ProfileFile)).?;
    defer allocator.free(profile2);
    try std.testing.expect(std.mem.startsWith(u8, notes2, notes1));
    try std.testing.expect(std.mem.endsWith(u8, notes2, user_note));
    try std.testing.expectEqualSlices(u8, profile1, profile2);

    // Third run: idempotent.
    const out3 = try dstore.profileWithNotes(allocator, f.journal, &v.visible, v.result);
    defer allocator.free(out3);
    try std.testing.expectEqualSlices(u8, out2, out3);

    // Pre-existing notes receive the legacy text blank-line separated.
    var g = try Fixture.init(allocator, io, ".tmp-phase7-e");
    defer g.deinit(allocator);
    try fillFixture(allocator, g.journal);
    const existing = "An earlier note.\n";
    try writeArtifact(g.journal.dir, io, dstore.NotesFile, existing);
    try writeArtifact(g.journal.dir, io, dstore.ProfileFile, legacy);
    var gv = try visibleOf(allocator, g.journal);
    defer gv.recs.deinit();
    defer gv.visible.deinit();
    _ = try dstore.profileWithNotes(allocator, g.journal, &gv.visible, gv.result);
    const gnotes = (try readArtifact(allocator, g.journal, dstore.NotesFile)).?;
    defer allocator.free(gnotes);
    try std.testing.expectEqualStrings(try allocator.print("{s}\n{s}", .{ existing, legacy }), gnotes);
}

test "phase 7: status reports states; rebuild restores; notes untouched" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase7-f");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    try writeArtifact(f.journal.dir, io, dstore.NotesFile, "user-owned\n");

    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();
    const range = view.DayRange{ .start = D0, .end = D0 + 1 };

    // Nothing derived yet: everything is missing.
    // (Reports are deinit-ed by hand, right after use: the status is the
    // only live derived value between reads.)
    var rep = try dstore.artifactStatus(allocator, f.journal, v.result);
    try std.testing.expectEqual(@as(usize, 3), rep.items.len);
    try std.testing.expectEqual(dstore.ArtifactState.missing, rep.items[0].state);
    try std.testing.expectEqual(dstore.ArtifactState.missing, rep.items[1].state);
    try std.testing.expectEqual(dstore.ArtifactState.missing, rep.items[2].state);
    rep.deinit();

    // Build the artifacts; the status flips to fresh. The vector artifact
    // ("embed") is not one of them: only `derived rebuild --embeddings`
    // builds it, and a pack never loads a model.
    _ = try dstore.contextPack(allocator, f.journal, &v.visible, v.result, "auth", range, true, null);
    rep = try dstore.artifactStatus(allocator, f.journal, v.result);
    try std.testing.expectEqual(@as(usize, 4), rep.items.len);
    try std.testing.expectEqual(dstore.ArtifactState.fresh, rep.items[0].state);
    try std.testing.expectEqual(@as(?u8, 1), rep.items[0].version);
    try std.testing.expectEqual(v.result.record_count, rep.items[0].record_count.?);
    try std.testing.expectEqual(dstore.ArtifactState.missing, rep.items[1].state);
    try std.testing.expectEqual(dstore.ArtifactState.fresh, rep.items[2].state);
    try std.testing.expectEqual(dstore.ArtifactState.fresh, rep.items[3].state);
    rep.deinit();

    // Corrupt the index footer: the hash check fails, status says corrupt.
    const idx = (try readArtifact(allocator, f.journal, dstore.IndexFile)).?;
    const idx_corrupt = try allocator.dupe(u8, idx);
    idx_corrupt[idx_corrupt.len - 1] ^= 0xFF;
    try writeArtifact(f.journal.dir, io, dstore.IndexFile, idx_corrupt);
    allocator.free(idx_corrupt);
    rep = try dstore.artifactStatus(allocator, f.journal, v.result);
    try std.testing.expectEqual(dstore.ArtifactState.corrupt, rep.items[0].state);
    rep.deinit();
    // A corrupt index is never served: the next pack rebuilds it.
    const pack = try dstore.contextPack(allocator, f.journal, &v.visible, v.result, "auth", range, true, null);
    allocator.free(pack);
    rep = try dstore.artifactStatus(allocator, f.journal, v.result);
    try std.testing.expectEqual(dstore.ArtifactState.fresh, rep.items[0].state);
    rep.deinit();

    // Move the head: everything goes stale, and the forced rebuild
    // brings it back — without ever touching notes.md.
    _ = try f.journal.appendRecord(allocator, .entry, 0, "stale check entry", &.{}, BASE + 36_000_000, 0, false);
    var v2 = try visibleOf(allocator, f.journal);
    defer v2.recs.deinit();
    defer v2.visible.deinit();
    rep = try dstore.artifactStatus(allocator, f.journal, v2.result);
    for (rep.items) |a| {
        // The vector artifact was never built here: it stays missing while
        // everything else goes stale.
        const want = if (std.mem.eql(u8, a.name, "embed")) dstore.ArtifactState.missing else dstore.ArtifactState.stale;
        try std.testing.expectEqual(want, a.state);
    }
    rep.deinit();
    const counts = try dstore.rebuild(allocator, f.journal, &v2.visible, v2.result);
    try std.testing.expect(counts.word_count > 0);
    rep = try dstore.artifactStatus(allocator, f.journal, v2.result);
    for (rep.items) |a| {
        // The rebuild restores index and profile; digests regenerate on
        // demand (they were deleted), and the vector artifact is still the
        // flag's job, not the rebuild's.
        const want = if (std.mem.eql(u8, a.name, "embed") or std.mem.startsWith(u8, a.name, dstore.DigestsDir ++ "/"))
            dstore.ArtifactState.missing
        else
            dstore.ArtifactState.fresh;
        try std.testing.expectEqual(want, a.state);
    }
    rep.deinit();
    const notes = (try readArtifact(allocator, f.journal, dstore.NotesFile)).?;
    try std.testing.expectEqualStrings("user-owned\n", notes);
    allocator.free(notes);
}

test "phase 7: a non-persisting pack (MCP) writes nothing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try Fixture.init(allocator, io, ".tmp-phase7-g");
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    var v = try visibleOf(allocator, f.journal);
    defer v.recs.deinit();
    defer v.visible.deinit();
    const range = view.DayRange{ .start = D0, .end = D0 + 1 };
    const question = "anything about auth?";

    const mem = try dstore.contextPack(allocator, f.journal, &v.visible, v.result, question, range, false, null);
    defer allocator.free(mem);
    // In-memory only: no artifacts exist on disk.
    try std.testing.expect((try readArtifact(allocator, f.journal, dstore.IndexFile)) == null);
    try std.testing.expect((try readArtifact(allocator, f.journal, dstore.ProfileFile)) == null);
    const d = (try readArtifact(allocator, f.journal, dstore.DigestsDir ++ "/2026-01-01_2026-01-01.digest")) == null;
    try std.testing.expect(d);

    // The persisting pack carries the same bytes.
    const disk = try dstore.contextPack(allocator, f.journal, &v.visible, v.result, question, range, true, null);
    defer allocator.free(disk);
    try std.testing.expectEqualSlices(u8, mem, disk);
}

// ---------------------------------------------------------------- helpers

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn writeArtifact(dir: Dir, io: Io, name: []const u8, bytes: []const u8) !void {
    var file = try Dir.createFile(dir, io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
