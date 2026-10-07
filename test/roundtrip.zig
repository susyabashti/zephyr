//! Phase 3 gate (slow part): write 100k synthetic entries, read them back,
//! identical. Also measures on-disk bytes per entry against a naive JSONL
//! baseline for the same entries.
//!
//! This is NOT part of the regular `test` step: the atomic whole-file
//! rewrite per append makes the total I/O quadratic in the largest segment,
//! so the run takes minutes. Run it with:  zig build roundtrip
//!
//! Entry profile (shared by both formats so the comparison is like-for-like):
//! 20-char text with a zero-padded index, one 3-char tag, UTC timezone.

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const N: u32 = 100_000;
const BASE_MS: u64 = 1_704_067_200_000; // 2024-01-01T00:00:00Z
/// 1040 s apart -> each UTC month holds ~2.5k entries (~40 months).
const STEP_MS: u64 = 1_040_000;

fn tsAt(i: u32) u64 {
    return BASE_MS + @as(u64, i) * STEP_MS;
}

fn textAt(allocator: Allocator, i: u32) Allocator.Error![]const u8 {
    return allocator.print("synthetic entry {d:0>6}", .{i});
}

test "phase 3: 100k-entry round trip" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-roundtrip", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    const journal = try core.journal.Journal.open(allocator, io, &environ, path, true);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    // appendRecord reads every segment file on each call and frees its
    // temporaries on return, so it must get an allocator that actually frees:
    // the arena would retain every file read (quadratic live memory).
    // std.heap.page_allocator is the plain allocating/freeing choice.
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const text = try textAt(allocator, i);
        const tags = [_][]const u8{"gen"};
        _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, text, &tags, tsAt(i), 0, false);
    }

    const ok0 = try journal.verify(allocator);
    try std.testing.expect(ok0.ok);
    try std.testing.expectEqual(@as(u64, N), ok0.record_count);

    // Read back identical.
    const recs = try journal.collectRecords(allocator);
    defer recs.deinit();
    i = 0;
    while (i < N) : (i += 1) {
        const h = recs.headers[i];
        try std.testing.expectEqual(h.record_type, .entry);
        try std.testing.expectEqual(h.seq, i);
        try std.testing.expectEqual(tsAt(i), h.timestamp_ms);
        const decoded = try core.records.decodePayload(allocator, recs.payloads[i]);
        defer allocator.free(decoded.tags);
        try std.testing.expectEqualStrings(try textAt(allocator, i), decoded.text);
        try std.testing.expectEqual(@as(usize, 1), decoded.tags.len);
        try std.testing.expectEqualStrings("gen", decoded.tags[0]);
    }

    // Bytes per entry vs the naive JSONL baseline (one object per line for
    // the same entries: timestamp, tz, private flag, text, tags).
    var journal_bytes: u64 = 0;
    for (recs.files) |f| journal_bytes += f.len;

    var jsonl = std.ArrayList(u8).empty;
    defer jsonl.deinit(allocator);
    i = 0;
    while (i < N) : (i += 1) {
        var buf: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"ts_ms\":{d},\"tz\":0,\"private\":false,\"text\":\"synthetic entry {d:0>6}\",\"tags\":[\"gen\"]}}\n", .{ tsAt(i), i }) catch unreachable;
        try jsonl.appendSlice(allocator, line);
    }

    std.debug.print("\nphase 3 round-trip gate\n", .{});
    std.debug.print("  entries:              {d}\n", .{N});
    std.debug.print("  segments:             {d}\n", .{recs.files.len});
    std.debug.print("  journal bytes:        {d}\n", .{journal_bytes});
    std.debug.print("  bytes/entry:          {d}\n", .{journal_bytes / N});
    std.debug.print("  JSONL bytes:          {d}\n", .{jsonl.items.len});
    std.debug.print("  JSONL bytes/entry:    {d}\n", .{jsonl.items.len / N});
    const ratio: f64 = @as(f64, @floatFromInt(journal_bytes)) / @as(f64, @floatFromInt(jsonl.items.len));
    std.debug.print("  ratio (zephyr/JSONL): {d:.2}\n", .{ratio});
}
