//! Phase 3 gate (fast part): an on-disk journal across monthly segment
//! boundaries.
//!
//!   - Round trip: every appended record reads back identical.
//!   - verify works across segment boundaries.
//!   - Tampering a SEALED segment (header, payload, or footer) is detected
//!     with the exact file, seq, and field.
//!
//! The 100k-entry round trip and the bytes-per-entry measurement live in
//! test/roundtrip.zig (slow; its own build step).

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const records = core.records;
const segment = core.segment;

const PER_MONTH = 100;

test "phase 3: cross-segment round trip and sealed tamper detection" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-phase3", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    const journal = try core.journal.Journal.open(allocator, io, &environ, path, true);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    // 300 entries over 3 UTC months -> 3 segments; appending the first
    // record of a new month seals the previous month's segment.
    const months = [_]u64{
        1_767_225_600_000, // 2026-01-01T00:00:00Z
        1_770_009_600_000, // 2026-02-01T00:00:00Z
        1_772_342_400_000, // 2026-03-01T00:00:00Z
    };
    var i: u32 = 0;
    for (months) |base| {
        const month_end = i + PER_MONTH;
        while (i < month_end) : (i += 1) {
            const text = try allocator.print("phase 3 entry {d}", .{i % PER_MONTH});
            const tags = [_][]const u8{"gen"};
            _ = try journal.appendRecord(allocator, .entry, 0, text, &tags, base + @as(u64, i % PER_MONTH) * 600_000, 0, false);
        }
    }

    // The clean journal verifies across all three segments.
    const ok0 = try journal.verify(allocator);
    try std.testing.expect(ok0.ok);
    try std.testing.expectEqual(@as(u64, 300), ok0.record_count);

    // Round trip: every record reads back identical.
    const recs = try journal.collectRecords(allocator);
    defer recs.deinit();
    try std.testing.expectEqual(@as(usize, 3), recs.files.len);
    i = 0;
    while (i < recs.headers.len) : (i += 1) {
        const h = recs.headers[i];
        try std.testing.expectEqual(h.record_type, .entry);
        try std.testing.expectEqual(h.seq, i);
        const month = i / PER_MONTH;
        try std.testing.expectEqual(months[month] + @as(u64, i % PER_MONTH) * 600_000, h.timestamp_ms);
        const decoded = try records.decodePayload(allocator, recs.payloads[i]);
        defer allocator.free(decoded.tags);
        try std.testing.expectEqualStrings(try allocator.print("phase 3 entry {d}", .{i % PER_MONTH}), decoded.text);
        try std.testing.expectEqual(@as(usize, 1), decoded.tags.len);
        try std.testing.expectEqualStrings("gen", decoded.tags[0]);
    }

    // Tamper the first (sealed) segment in three places; after each, verify
    // must fail with the exact location, and the journal must recover to
    // clean state when the original bytes are restored.
    const name = "2026-01.zph";
    const pristine = try readSeg(allocator, io, path, name);
    defer allocator.free(pristine);

    // Record 5's stored record_hash. Each 125-byte block is [record_hash(32) ‖
    // header(93)]; parse compares the block's leading copy with the header's
    // own record_hash field, so flipping a leading byte is detected at parse
    // time (StoredHashMismatch) with the exact record index.
    try flipSeg(allocator, io, path, name, pristine, 30 + 125 * 5 + 3);
    var bad = try journal.verify(allocator);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings(name, bad.issue.?.file);
    try std.testing.expectEqual(@as(u64, 5), bad.issue.?.seq);
    try std.testing.expectEqualStrings("record_hash", bad.issue.?.field);
    try writeSeg(allocator, io, path, name, pristine);

    // Record 0's payload salt (payload region starts at 30 + 125*100, each
    // payload is 4-byte length-prefixed; the salt is the payload's first
    // 32 bytes and is not content-validated, so a flipped salt byte breaks
    // the commitment without breaking the payload structure).
    try flipSeg(allocator, io, path, name, pristine, 30 + 125 * 100 + 4 + 3);
    bad = try journal.verify(allocator);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings(name, bad.issue.?.file);
    try std.testing.expectEqual(@as(u64, 0), bad.issue.?.seq);
    try std.testing.expectEqualStrings("commitment", bad.issue.?.field);
    try writeSeg(allocator, io, path, name, pristine);

    // A byte of the footer hash (the footer's last 32 bytes).
    try flipSeg(allocator, io, path, name, pristine, pristine.len - 5);
    bad = try journal.verify(allocator);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings(name, bad.issue.?.file);
    try std.testing.expectEqualStrings("footer", bad.issue.?.field);
    try writeSeg(allocator, io, path, name, pristine);

    // Restored journal verifies again.
    const ok1 = try journal.verify(allocator);
    try std.testing.expect(ok1.ok);
    try std.testing.expectEqual(@as(u64, 300), ok1.record_count);
}

fn readSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8) (Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError)![]u8 {
    const d = try Dir.openDirAbsolute(io, dir_path, .{});
    defer Dir.close(d, io);
    return try Dir.readFileAlloc(d, io, name, allocator, .unlimited);
}

fn writeSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8, data: []const u8) (Allocator.Error || Dir.OpenError || segment.WriteError)!void {
    _ = allocator;
    const d = try Dir.openDirAbsolute(io, dir_path, .{});
    defer Dir.close(d, io);
    return segment.writeAtomic(d, io, name, data);
}

fn flipSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8, pristine: []const u8, offset: usize) (Allocator.Error || Dir.OpenError || segment.WriteError)!void {
    var data = try allocator.dupe(u8, pristine);
    defer allocator.free(data);
    data[offset] ^= 0x01;
    return writeSeg(allocator, io, dir_path, name, data);
}
