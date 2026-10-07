//! Phase 5 gate: redaction and anchors on an on-disk journal.
//!
//!   - Redaction (including the first entry, seq 0) removes the payload
//!     bytes but keeps the headers, the chain, and the commitments, so the
//!     redaction is visible and the tamper detection stays intact.
//!   - Tail truncation passes `verify` (a valid sealed prefix) but is caught
//!     by the anchor check.
//!   - A full rewrite with the same record count also passes `verify` but
//!     cannot reproduce the anchored head, so the anchor check catches it.
//!
//! The anchor bytes themselves are pinned by the Phase 5 vector suite
//! (test/anchors.zig, spec/vectors/anchors.json) and the independent Python
//! reference.

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;

const records = core.records;
const segment = core.segment;
const view = core.view;

const BASE_JAN: u64 = 1_767_225_600_000; // 2026-01-01T00:00:00Z
const BASE_FEB: u64 = 1_770_009_600_000; // 2026-02-01T00:00:00Z

// ---------------------------------------------------------------- helpers

fn readSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8) (Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError)![]u8 {
    const d = try Dir.openDirAbsolute(io, dir_path, .{});
    defer Dir.close(d, io);
    return try Dir.readFileAlloc(d, io, name, allocator, .unlimited);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Appends a checkpoint record and writes its anchor artifact, signed with
/// the deterministic test key `seed`.
const CheckpointError = Allocator.Error || core.journal.Journal.AppendError || core.journal.Journal.VerifyError ||
    core.anchor.SignError || core.journal.Journal.WriteAnchorError || error{ VerifyFailed, KeyGeneration };

fn takeCheckpoint(
    journal: *const core.journal.Journal,
    allocator: Allocator,
    seed: [32]u8,
    timestamp_ms: u64,
) CheckpointError!u64 {
    const seq = try journal.appendRecord(std.heap.page_allocator, .checkpoint, 0, "", &.{}, timestamp_ms, 0, false);
    const result = try journal.verify(allocator);
    if (!result.ok) return error.VerifyFailed;
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch |err| switch (err) {
        error.IdentityElement => return error.KeyGeneration,
    };
    const bytes = try core.anchor.render(&kp, result.head, result.record_count, timestamp_ms, seq);
    try journal.writeAnchorFile(allocator, seq, &bytes);
    return seq;
}

fn freshJournal(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map, cwd: Dir, path: []const u8) !core.journal.Journal {
    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    return core.journal.Journal.open(allocator, io, environ, path, true);
}

// ---------------------------------------------------------------- tests

test "phase 5: redaction removes content, keeps the chain" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-phase5", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    const journal = try freshJournal(allocator, io, &environ, cwd, path);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    // Entry 0 with a unique marker, an amendment on it (unique text), and a
    // second entry that must survive the redaction.
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "REDACT-MARKER-7a3c", &.{}, BASE_JAN, 0, false);
    _ = try journal.appendRecord(std.heap.page_allocator, .amendment, 0, "amended marker 9d2e", &.{}, BASE_JAN + 600_000, 0, false);
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "untouched entry", &.{}, BASE_JAN + 1_200_000, 0, false);

    const seg_name = "2026-01.zph";
    const before = try readSeg(allocator, io, path, seg_name);
    defer allocator.free(before);
    // The entry 0 payload's salt (payload region starts after the 125-byte
    // header blocks; each payload is 4-byte length-prefixed).
    const salt_before = before[30 + 125 * 3 + 4 .. 30 + 125 * 3 + 4 + 32];
    // The random salt must not be the all-zero pattern, which also occurs
    // inside the redaction placeholder (the "salt is gone" check would be
    // vacuous in that case).
    var salt_is_zero = true;
    for (salt_before) |b| {
        if (b != 0) {
            salt_is_zero = false;
            break;
        }
    }
    try std.testing.expect(!salt_is_zero);

    const red_seq = try journal.redact(std.heap.page_allocator, 0, BASE_JAN + 1_800_000, 0);
    try std.testing.expectEqual(@as(u64, 3), red_seq);

    const after = try readSeg(allocator, io, path, seg_name);
    defer allocator.free(after);

    // The 125-byte header blocks of the redacted records are byte-identical:
    // the chain and the commitments are untouched, so the redaction cannot be
    // matched against guessed content.
    try std.testing.expect(std.mem.eql(u8, before[30 + 125 * 0 .. 30 + 125 * 1], after[30 + 125 * 0 .. 30 + 125 * 1]));
    try std.testing.expect(std.mem.eql(u8, before[30 + 125 * 1 .. 30 + 125 * 2], after[30 + 125 * 1 .. 30 + 125 * 2]));
    // The file header keeps magic/version/flags/start_seq; record_count and
    // header_region_len grow by one (the appended redaction record), and
    // payload_region_len is patched to the redacted size.
    try std.testing.expect(std.mem.eql(u8, before[0..6], after[0..6]));
    try std.testing.expect(std.mem.eql(u8, before[6..14], after[6..14]));
    try std.testing.expect(!std.mem.eql(u8, before[14..22], after[14..22]));
    try std.testing.expect(!std.mem.eql(u8, before[22..26], after[22..26]));
    // Exact sizes: payloads 57+58+54 -> 39+39+54, plus the redaction record
    // (125-byte block + 4+35 payload): 30+375+169 -> 30+500+132+39.
    try std.testing.expectEqual(@as(usize, 574), before.len);
    try std.testing.expectEqual(@as(usize, 701), after.len);

    // The content is gone from the file; the surviving entry is not.
    try std.testing.expect(!contains(after, "REDACT-MARKER-7a3c"));
    try std.testing.expect(!contains(after, "amended marker 9d2e"));
    try std.testing.expect(!contains(after, salt_before));
    try std.testing.expect(contains(after, "untouched entry"));

    // verify passes and reports exactly one redacted entry.
    const ok = try journal.verify(allocator);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqual(@as(u64, 4), ok.record_count);
    try std.testing.expectEqual(@as(u64, 1), ok.redacted_count);

    // The entry's and the amendment's payloads are the all-zero placeholder.
    const recs = try journal.collectRecords(allocator);
    defer recs.deinit();
    try std.testing.expect(records.isRedactedPlaceholder(recs.payloads[0]));
    try std.testing.expect(records.isRedactedPlaceholder(recs.payloads[1]));

    // The LLM view shows [redacted] and never the removed text.
    const rendered = try view.render(allocator, recs.headers, recs.payloads);
    try std.testing.expect(contains(rendered, "[redacted]"));
    try std.testing.expect(!contains(rendered, "REDACT-MARKER-7a3c"));
    try std.testing.expect(!contains(rendered, "amended marker 9d2e"));
    try std.testing.expect(contains(rendered, "untouched entry"));

    // Redacting the same entry twice is refused.
    try std.testing.expectError(error.AlreadyRedacted, journal.redact(std.heap.page_allocator, 0, BASE_JAN + 2_400_000, 0));
    // A missing target and a non-entry target are reported.
    try std.testing.expectError(error.TargetNotFound, journal.redact(std.heap.page_allocator, 99, BASE_JAN + 3_000_000, 0));
    try std.testing.expectError(error.TargetNotEntry, journal.redact(std.heap.page_allocator, 3, BASE_JAN + 3_600_000, 0));
}

test "phase 5: tail truncation is caught by the anchor" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-phase5a", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    const journal = try freshJournal(allocator, io, &environ, cwd, path);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    const seed: [32]u8 = @splat(7); // fixed test-only key
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "jan one", &.{}, BASE_JAN, 0, false);
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "jan two", &.{}, BASE_JAN + 600_000, 0, false);
    try std.testing.expectEqual(@as(u64, 2), try takeCheckpoint(&journal, allocator, seed, BASE_JAN + 1_200_000));
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "feb one", &.{}, BASE_FEB, 0, false);
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "feb two", &.{}, BASE_FEB + 600_000, 0, false);
    try std.testing.expectEqual(@as(u64, 5), try takeCheckpoint(&journal, allocator, seed, BASE_FEB + 1_200_000));

    // Clean state: the latest anchor (checkpoint seq 5) links.
    const clean = try journal.checkAnchors(allocator);
    try std.testing.expect(clean.failure == null);
    const clean_check = clean.ok orelse return error.AnchorUnexpectedlyMissing;
    try std.testing.expectEqual(@as(u64, 5), clean_check.artifact.checkpoint_seq);

    // Truncate: delete the February segment. The remaining journal is a
    // valid sealed prefix, so verify still passes...
    const d = try Dir.openDirAbsolute(io, path, .{});
    defer Dir.close(d, io);
    Dir.deleteFile(d, io, "2026-02.zph") catch |err| return err;
    const ok = try journal.verify(allocator);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqual(@as(u64, 3), ok.record_count);
    // ...but the anchor check fails: the journal is shorter than the anchor.
    const truncated = try journal.checkAnchors(allocator);
    const failure = truncated.failure orelse return error.AnchorUnexpectedlyOk;
    try std.testing.expect(failure == error.CountRegression);
    try std.testing.expectEqualStrings("checkpoint-5.zpa", truncated.file_name.?);
}

test "phase 5: a full rewrite is caught by the anchor" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path_a = try allocator.print("{s}/.tmp-phase5b", .{cwd_path});
    const path_b = try allocator.print("{s}/.tmp-phase5c", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    const journal_a = try freshJournal(allocator, io, &environ, cwd, path_a);
    defer {
        journal_a.close();
        Dir.deleteTree(cwd, io, path_a) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
        Dir.deleteTree(cwd, io, path_b) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    const seed: [32]u8 = @splat(9); // fixed test-only key
    // Original journal: 4 entries + a checkpoint (5 records).
    _ = try journal_a.appendRecord(std.heap.page_allocator, .entry, 0, "original one", &.{}, BASE_JAN, 0, false);
    _ = try journal_a.appendRecord(std.heap.page_allocator, .entry, 0, "original two", &.{}, BASE_JAN + 600_000, 0, false);
    _ = try journal_a.appendRecord(std.heap.page_allocator, .entry, 0, "orig feb one", &.{}, BASE_FEB, 0, false);
    _ = try journal_a.appendRecord(std.heap.page_allocator, .entry, 0, "orig feb two", &.{}, BASE_FEB + 600_000, 0, false);
    try std.testing.expectEqual(@as(u64, 4), try takeCheckpoint(&journal_a, allocator, seed, BASE_FEB + 1_200_000));

    // The anchor bytes are the external copy (git/second device).
    const anchors_dir = try Dir.openDirAbsolute(io, try allocator.print("{s}/anchors", .{path_a}), .{});
    defer Dir.close(anchors_dir, io);
    const anchor_bytes = try Dir.readFileAlloc(anchors_dir, io, "checkpoint-4.zpa", allocator, .unlimited);

    // The rewrite: a fresh journal with different text but the same shape
    // (same months, same record count). Its own chain verifies cleanly...
    const journal_b = try freshJournal(allocator, io, &environ, cwd, path_b);
    _ = try journal_b.appendRecord(std.heap.page_allocator, .entry, 0, "rewritten one", &.{}, BASE_JAN, 0, false);
    _ = try journal_b.appendRecord(std.heap.page_allocator, .entry, 0, "rewritten two", &.{}, BASE_JAN + 600_000, 0, false);
    _ = try journal_b.appendRecord(std.heap.page_allocator, .entry, 0, "rewrite feb one", &.{}, BASE_FEB, 0, false);
    _ = try journal_b.appendRecord(std.heap.page_allocator, .entry, 0, "rewrite feb two", &.{}, BASE_FEB + 600_000, 0, false);
    _ = try journal_b.appendRecord(std.heap.page_allocator, .checkpoint, 0, "", &.{}, BASE_FEB + 1_200_000, 0, false);
    const ok = try journal_b.verify(allocator);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqual(@as(u64, 5), ok.record_count);

    // ...but it cannot reproduce the anchored head, so the check fails.
    try journal_b.writeAnchorFile(allocator, 4, anchor_bytes);
    const rewritten = try journal_b.checkAnchors(allocator);
    const failure = rewritten.failure orelse return error.AnchorUnexpectedlyOk;
    try std.testing.expect(failure == error.CheckpointMissing);
    try std.testing.expectEqualStrings("checkpoint-4.zpa", rewritten.file_name.?);
}
