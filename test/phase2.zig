//! Phase 2 gate: views, amendments, tombstones, and search on a fixture
//! journal on disk. All timestamps are pinned, so the output is deterministic.
//!
//! Fixture (tz +120 throughout):
//!   seq 0   entry           2026-01-15T23:45Z  local 01-16 01:45  (midnight crossing)
//!   seq 1   entry           2026-01-16T10:30Z  local 01-16 12:30  (amended twice)
//!   seq 2   entry           2026-01-17T23:00Z  local 01-18 01:00  (tombstoned)
//!   seq 3   entry (private) 2026-01-18T09:00Z  local 01-18 11:00
//!   seq 4   amendment -> 1  2026-01-18T10:00Z
//!   seq 5   tombstone -> 2  2026-01-18T11:00Z
//!   seq 6   entry           2026-01-19T08:00Z  local 01-19 10:00

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const TZ: i16 = 120;

test "phase 2: views, amendments, tombstones, search" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-phase2", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    const journal = try core.journal.Journal.open(allocator, io, &environ, path, true);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    // ---- build the fixture
    const travel_city = [_][]const u8{ "travel", "city" };
    const work = [_][]const u8{"work"};
    _ = try journal.appendRecord(allocator, .entry, 0, "first day in the city", &travel_city, 1_768_520_700_000, TZ, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "second entry", &work, 1_768_559_400_000, TZ, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "entry to hide", &.{}, 1_768_690_800_000, TZ, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "secret note", &.{}, 1_768_726_800_000, TZ, true);
    const work_updated = [_][]const u8{ "work", "updated" };
    _ = try journal.appendRecord(allocator, .amendment, 1, "second entry (amended)", &work_updated, 1_768_730_400_000, TZ, false);
    _ = try journal.appendRecord(allocator, .tombstone, 2, "", &.{}, 1_768_734_000_000, TZ, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "third entry", &.{}, 1_768_809_600_000, TZ, false);

    const ok0 = try journal.verify(allocator);
    try std.testing.expect(ok0.ok);
    try std.testing.expectEqual(@as(u64, 7), ok0.record_count);

    const recs0 = try journal.collectRecords(allocator);
    defer recs0.deinit();
    const head_hex = try hexOf(allocator, &recs0.headers[6].record_hash);

    const day15 = try day(allocator, 2026, 1, 15);
    const day16 = try day(allocator, 2026, 1, 16);
    const day18 = try day(allocator, 2026, 1, 18);
    const day19 = try day(allocator, 2026, 1, 19);

    // ---- date views: boundaries are the entry's LOCAL day
    // 2026-01-15 (seq 0's UTC date) must be empty; its local day is 01-16.
    try expectRender(allocator, recs0, .{ .start = day15, .end = day15 + 1 }, try prov(allocator, head_hex));

    const on16 =
        \\# zephyr: seq 0..6 head=HEX
        \\# 2026-01-16 Fri
        \\01:45 [travel][city] first day in the city
        \\12:30 (edited) [work][updated] second entry (amended)
        \\
    ;
    try expectRender(allocator, recs0, .{ .start = day16, .end = day16 + 1 }, try withHead(allocator, on16, head_hex));

    // 01-18 holds only the tombstoned and private entries: provenance only.
    try expectRender(allocator, recs0, .{ .start = day18, .end = day18 + 1 }, try prov(allocator, head_hex));

    const on19 =
        \\# zephyr: seq 0..6 head=HEX
        \\# 2026-01-19 Mon
        \\10:00 third entry
        \\
    ;
    try expectRender(allocator, recs0, .{ .start = day19, .end = day19 + 1 }, try withHead(allocator, on19, head_hex));

    // The ISO week containing Friday 01-16 starts Monday 01-12 and ends
    // before 01-19: same body as the 01-16 view.
    const monday = core.view.weekStart(day16);
    expectMonday(2026, 1, 12, monday);
    try expectRender(allocator, recs0, .{ .start = monday, .end = monday + 7 }, try withHead(allocator, on16, head_hex));

    // ---- search: viewable effective text, case-insensitive
    try expectSearch(allocator, recs0, "entry",
        \\# 2 matches for "entry"
        \\0001  2026-01-16 12:30  [work][updated] second entry (amended)
        \\0006  2026-01-19 10:00  third entry
        \\
    );
    // The tombstoned entry ("entry to hide") and the private one are not
    // viewable, so they never match.
    try expectSearch(allocator, recs0, "hide",
        \\# 0 matches for "hide"
        \\
    );

    // ---- edit: amendment changes the view, verify passes, original remains
    const work_final = [_][]const u8{ "work", "final" };
    const amend_seq = try journal.appendRecord(allocator, .amendment, 1, "second entry (final)", &work_final, 1_768_813_200_000, TZ, false);
    try std.testing.expectEqual(@as(u64, 7), amend_seq);
    const ok1 = try journal.verify(allocator);
    try std.testing.expect(ok1.ok);
    try std.testing.expectEqual(@as(u64, 8), ok1.record_count);

    const recs1 = try journal.collectRecords(allocator);
    defer recs1.deinit();
    const head1_hex = try hexOf(allocator, &recs1.headers[7].record_hash);
    const on16_edited =
        \\# zephyr: seq 0..7 head=HEX
        \\# 2026-01-16 Fri
        \\01:45 [travel][city] first day in the city
        \\12:30 (edited) [work][final] second entry (final)
        \\
    ;
    try expectRender(allocator, recs1, .{ .start = day16, .end = day16 + 1 }, try withHead(allocator, on16_edited, head1_hex));
    // The original record is still present, byte for byte.
    const original = try core.records.decodePayload(allocator, recs1.payloads[1]);
    defer allocator.free(original.tags);
    try std.testing.expectEqualStrings("second entry", original.text);
    try std.testing.expectEqual(@as(usize, 1), original.tags.len);
    try std.testing.expectEqualStrings("work", original.tags[0]);

    // ---- rm: tombstone hides the entry, verify passes, original remains
    const tomb_seq = try journal.appendRecord(allocator, .tombstone, 6, "", &.{}, 1_768_816_800_000, TZ, false);
    try std.testing.expectEqual(@as(u64, 8), tomb_seq);
    const ok2 = try journal.verify(allocator);
    try std.testing.expect(ok2.ok);
    try std.testing.expectEqual(@as(u64, 9), ok2.record_count);

    const recs2 = try journal.collectRecords(allocator);
    defer recs2.deinit();
    const head2_hex = try hexOf(allocator, &recs2.headers[8].record_hash);
    try expectRender(allocator, recs2, .{ .start = day19, .end = day19 + 1 }, try prov8(allocator, head2_hex));
    const hidden = try core.records.decodePayload(allocator, recs2.payloads[6]);
    defer allocator.free(hidden.tags);
    try std.testing.expectEqualStrings("third entry", hidden.text);

    try expectSearch(allocator, recs2, "entry",
        \\# 1 match for "entry"
        \\0001  2026-01-16 12:30  [work][final] second entry (final)
        \\
    );

    // ---- target resolution errors
    try std.testing.expectError(error.TargetNotFound, core.journal.Journal.resolveEditTarget(recs2.headers, 99));
    try std.testing.expectError(error.TargetNotEntry, core.journal.Journal.resolveEditTarget(recs2.headers, 4));
    // The first entry is targetable: spec 3.1 only requires the target to be
    // strictly earlier than the record, so seq 0 is a legal target.
    const target0 = core.journal.Journal.resolveEditTarget(recs2.headers, 0) catch unreachable;
    try std.testing.expectEqual(@as(u64, 0), target0.seq);
}

// ---- helpers

const ExpectError = core.view.RenderError || error{TestExpectedEqual};

fn day(allocator: Allocator, year: i64, month: u64, d: u64) Allocator.Error!i64 {
    _ = allocator;
    return core.view.dateToCivilDay(year, month, d) orelse @panic("bad fixture date");
}

fn expectMonday(year: u16, month: u4, day_of_month: u5, got: i64) void {
    const c = core.view.civilDate(got) catch @panic("bad week start");
    if (c.year != year or c.month != month or c.day != day_of_month) {
        std.debug.print("expected Monday {d:0>4}-{d:0>2}-{d:0>2}, got {d:0>4}-{d:0>2}-{d:0>2}\n", .{
            year, month, day_of_month, c.year, c.month, c.day,
        });
        @panic("wrong week start");
    }
}

fn prov(allocator: Allocator, head_hex: []const u8) Allocator.Error![]const u8 {
    return try allocator.print("# zephyr: seq 0..6 head={s}\n", .{head_hex});
}

fn prov8(allocator: Allocator, head_hex: []const u8) Allocator.Error![]const u8 {
    return try allocator.print("# zephyr: seq 0..8 head={s}\n", .{head_hex});
}

/// Substitutes the computed head hash into a golden string.
fn withHead(allocator: Allocator, golden: []const u8, head_hex: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, golden, from, "HEX")) |at| {
        try out.appendSlice(allocator, golden[from..at]);
        try out.appendSlice(allocator, head_hex);
        from = at + 3;
    }
    try out.appendSlice(allocator, golden[from..]);
    return out.toOwnedSlice(allocator);
}

fn expectRender(allocator: Allocator, recs: core.journal.Journal.RecordSet, range: core.view.DayRange, want: []const u8) ExpectError!void {
    const got = try core.view.renderRange(allocator, recs.headers, recs.payloads, range);
    defer allocator.free(got);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("view mismatch (got {d} bytes, want {d} bytes)\n--- got ---\n{s}--- want ---\n{s}\n", .{
            got.len, want.len, got, want,
        });
        return error.TestExpectedEqual;
    }
}

fn expectSearch(allocator: Allocator, recs: core.journal.Journal.RecordSet, query: []const u8, want: []const u8) ExpectError!void {
    const visible = try core.view.visibleEntries(allocator, recs.headers, recs.payloads);
    defer visible.deinit();
    const matches = try core.search.find(allocator, &visible, query);
    defer allocator.free(matches);
    const got = try core.search.render(allocator, matches, query);
    defer allocator.free(got);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("search mismatch (got {d} bytes, want {d} bytes)\n--- got ---\n{s}--- want ---\n{s}\n", .{
            got.len, want.len, got, want,
        });
        return error.TestExpectedEqual;
    }
}

fn hexOf(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, hash.len * 2);
    for (hash, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}
