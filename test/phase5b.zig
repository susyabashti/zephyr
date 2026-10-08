//! Phase 5b gate: OpenTimestamps anchors on an on-disk journal.
//!
//!   - A sealed segment's footer head is the stamped document: a synthetic
//!     proof over SHA-256(footer head) writes to anchors/ots-<month>.ots
//!     and the journal's ots anchor check accepts it.
//!   - Redaction invariance: redacting an entry in a sealed segment keeps
//!     the footer (and therefore the anchor) intact.
//!   - A full rewrite of a month with different content passes `verify` but
//!     cannot reproduce the stamped head, so the ots anchor check fails
//!     with DigestMismatch.
//!   - An anchor referencing a missing segment is SegmentMissing.
//!
//! The proof bytes themselves are pinned by the Phase 5b vector suite
//! (test/ots.zig, spec/vectors/ots.json) and the independent Python
//! reference.

const std = @import("std");
const core = @import("zephyr_core");
const ots_util = @import("ots_util.zig");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const records = core.records;
const segment = core.segment;

const BASE_JAN: u64 = 1_767_225_600_000; // 2026-01-01T00:00:00Z
const BASE_FEB: u64 = 1_770_009_600_000; // 2026-02-01T00:00:00Z

// ---------------------------------------------------------------- helpers

const TestError = Allocator.Error || core.journal.Journal.AppendError ||
    core.journal.Journal.VerifyError || core.journal.Journal.RedactError ||
    core.journal.Journal.CheckOtsAnchorsError || core.journal.Journal.WriteAnchorError ||
    core.segment.FooterHeadError || Dir.OpenError || Dir.ReadFileAllocError ||
    std.process.CurrentPathError || error{CheckFailed};

fn readSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8) (Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError)![]u8 {
    const d = try Dir.openDirAbsolute(io, dir_path, .{});
    defer Dir.close(d, io);
    return try Dir.readFileAlloc(d, io, name, allocator, .unlimited);
}

fn freshJournal(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map, cwd: Dir, path: []const u8) !core.journal.Journal {
    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    return core.journal.Journal.open(allocator, io, environ, path, true);
}

/// The stamped file digest of a sealed segment: SHA-256 of the footer head.
fn stampedDigest(seg_bytes: []const u8) TestError![32]u8 {
    const head = try segment.footerHead(seg_bytes);
    var digest: [32]u8 = undefined;
    records.Sha256.hash(&head, &digest, .{});
    return digest;
}

/// Appends the jan/feb records that seal 2026-01 and returns the synthetic
/// proof over the stamped digest.
fn buildStampedJan(
    journal: *const core.journal.Journal,
    allocator: Allocator,
    jan_text: []const u8,
) TestError![]u8 {
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, jan_text, &.{}, BASE_JAN, 0, false);
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "jan two", &.{}, BASE_JAN + 600_000, 0, false);
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "feb one", &.{}, BASE_FEB, 0, false);
    const jan = try readSeg(allocator, std.testing.io, journal.path, "2026-01.zph");
    defer allocator.free(jan);
    const digest = try stampedDigest(jan);
    return ots_util.syntheticProof(allocator, &digest, 12345);
}

// ---------------------------------------------------------------- tests

test "phase 5b: a synthetic ots anchor verifies, and survives redaction" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-ots-a", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    const journal = try freshJournal(allocator, io, &environ, cwd, path);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    const proof = try buildStampedJan(&journal, allocator, "jan one");
    try journal.writeOtsAnchorFile(allocator, "2026-01", proof);

    const checks = try journal.checkOtsAnchors(allocator);
    try std.testing.expectEqual(@as(usize, 1), checks.len);
    const check = checks[0];
    try std.testing.expectEqualStrings("ots-2026-01.ots", check.file_name);
    try std.testing.expectEqualStrings("2026-01.zph", check.segment_name);
    try std.testing.expect(check.ok);
    try std.testing.expect(check.failure == null);
    try std.testing.expectEqual(@as(usize, 1), check.attestations.len);
    try std.testing.expect(check.attestations[0].attestation == .bitcoin);
    try std.testing.expectEqual(@as(u64, 12345), check.attestations[0].attestation.bitcoin);

    // The stamp must not have disturbed the journal's own verification.
    const clean = try journal.verify(allocator);
    try std.testing.expect(clean.ok);
    try std.testing.expectEqual(@as(u64, 3), clean.record_count);

    // Redaction invariance: redact a January entry from February. The
    // redaction record lands in the (current) February segment; the January
    // payload is replaced, but the sealed footer is byte-identical, so the
    // anchor still verifies.
    const jan_before = try readSeg(allocator, io, path, "2026-01.zph");
    defer allocator.free(jan_before);
    _ = try journal.redact(allocator, 0, BASE_FEB + 600_000, 0);

    const ok = try journal.verify(allocator);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqual(@as(u64, 4), ok.record_count);
    try std.testing.expectEqual(@as(u64, 1), ok.redacted_count);

    const jan_after = try readSeg(allocator, io, path, "2026-01.zph");
    defer allocator.free(jan_after);
    try std.testing.expect(jan_before.len != jan_after.len); // payload region shrank
    try std.testing.expect(std.mem.eql(u8, jan_before[jan_before.len - segment.FooterLen ..], jan_after[jan_after.len - segment.FooterLen ..]));

    const checks_after = try journal.checkOtsAnchors(allocator);
    try std.testing.expectEqual(@as(usize, 1), checks_after.len);
    try std.testing.expect(checks_after[0].ok);
}

test "phase 5b: a rewritten month is caught by the ots anchor" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path_a = try allocator.print("{s}/.tmp-ots-b", .{cwd_path});
    const path_b = try allocator.print("{s}/.tmp-ots-c", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    const journal_a = try freshJournal(allocator, io, &environ, cwd, path_a);
    const journal_b = try freshJournal(allocator, io, &environ, cwd, path_b);
    defer {
        journal_a.close();
        journal_b.close();
        Dir.deleteTree(cwd, io, path_a) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
        Dir.deleteTree(cwd, io, path_b) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    // The proof bytes are the external copy (git / second device).
    const proof = try buildStampedJan(&journal_a, allocator, "original one");

    // The rewrite: a fresh journal with different January content but the
    // same shape (same months, same record count). Its own chain verifies
    // cleanly...
    _ = try journal_b.appendRecord(std.heap.page_allocator, .entry, 0, "rewritten one", &.{}, BASE_JAN, 0, false);
    _ = try journal_b.appendRecord(std.heap.page_allocator, .entry, 0, "rewritten two", &.{}, BASE_JAN + 600_000, 0, false);
    _ = try journal_b.appendRecord(std.heap.page_allocator, .entry, 0, "rewritten feb", &.{}, BASE_FEB, 0, false);
    const ok = try journal_b.verify(allocator);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqual(@as(u64, 3), ok.record_count);

    // ...but it cannot reproduce the stamped head, so the check fails.
    try journal_b.writeOtsAnchorFile(allocator, "2026-01", proof);
    const checks = try journal_b.checkOtsAnchors(allocator);
    try std.testing.expectEqual(@as(usize, 1), checks.len);
    try std.testing.expect(!checks[0].ok);
    const failure = checks[0].failure orelse return error.CheckFailed;
    try std.testing.expect(failure == error.DigestMismatch);
}

test "phase 5b: an anchor for a missing segment is SegmentMissing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-ots-d", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    const journal = try freshJournal(allocator, io, &environ, cwd, path);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "only entry", &.{}, BASE_JAN, 0, false);
    // The proof bytes are irrelevant: the referenced segment is missing
    // before any proof parsing happens.
    try journal.writeOtsAnchorFile(allocator, "2020-01", &[_]u8{ 1, 2, 3, 4 });

    const ok = try journal.verify(allocator);
    try std.testing.expect(ok.ok);

    const checks = try journal.checkOtsAnchors(allocator);
    try std.testing.expectEqual(@as(usize, 1), checks.len);
    try std.testing.expectEqualStrings("ots-2020-01.ots", checks[0].file_name);
    try std.testing.expectEqualStrings("2020-01.zph", checks[0].segment_name);
    try std.testing.expect(!checks[0].ok);
    const failure = checks[0].failure orelse return error.CheckFailed;
    try std.testing.expect(failure == error.SegmentMissing);
}
