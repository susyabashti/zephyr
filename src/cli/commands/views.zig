//! zephyr today | yesterday | week | on YYYY-MM-DD — render the journal's
//! visible entries for a period (local civil days under the journal's
//! timezone).

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn runDayView(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    which: []const u8,
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    // "Today" is the current civil day in the local timezone.
    const now_ms = cli_journal.nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const today = try core.view.localDay(now_ms, offset);
    const range = if (std.mem.eql(u8, which, "today"))
        core.view.DayRange{ .start = today, .end = today + 1 }
    else if (std.mem.eql(u8, which, "yesterday"))
        core.view.DayRange{ .start = today - 1, .end = today }
    else blk: {
        // ISO week: Monday through Sunday containing today.
        const monday = core.view.weekStart(today);
        break :blk core.view.DayRange{ .start = monday, .end = monday + 7 };
    };
    try renderJournalRange(arena, &journal, style, out, io, range);
}

pub fn runRangeView(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    range: core.view.DayRange,
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    try renderJournalRange(arena, &journal, style, out, io, range);
}

fn renderJournalRange(
    arena: Allocator,
    journal: *const core.journal.Journal,
    style: output.Style,
    out: File,
    io: Io,
    range: core.view.DayRange,
) errors.RunError!void {
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    if (style.enabled) {
        // The styled TTY view; piped output (and $NO_COLOR) keeps the
        // frozen bytes from core.view.renderRange, untouched.
        const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
        defer visible.deinit();
        const rendered = try renderStyledRange(arena, style, visible.entries, range);
        try output.printBlock(out, io, rendered);
    } else {
        const rendered = try core.view.renderRange(arena, recs.headers, recs.payloads, range);
        try output.printBlock(out, io, rendered);
    }
}

/// The styled day view (TTY only). The same layout as the frozen view
/// (core.view.renderRange): one date header per day, a blank line between
/// days, entry lines `  SEQ  HH:MM …` — with the seq accented (the handle
/// for edit/rm/redact, the same cyan as the ✓ lines), the weekday and the
/// time dimmed, and the text at full weight, so the day structure reads at
/// a glance.
fn renderStyledRange(
    arena: Allocator,
    style: output.Style,
    entries: []const core.view.ViewEntry,
    range: core.view.DayRange,
) core.view.RenderError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(arena);
    var seq_buf: [20]u8 = undefined; // u64 decimal
    var date_buf: [16]u8 = undefined;
    var current_day: ?i64 = null;
    for (entries) |entry| {
        if (entry.day < range.start or entry.day >= range.end) continue;
        if (current_day == null or current_day.? != entry.day) {
            if (out.items.len > 0) try out.append(arena, '\n'); // blank line between days
            const date = core.view.civilDate(entry.day) catch return error.TimestampOutOfRange;
            const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ date.year, date.month, date.day }) catch unreachable;
            try out.appendSlice(arena, try style.bold(arena, date_str));
            try out.append(arena, ' ');
            try out.appendSlice(arena, try style.dim(arena, core.view.weekdayName(entry.day)));
            try out.append(arena, '\n');
            current_day = entry.day;
        }
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d}", .{entry.seq}) catch unreachable;
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, try style.accent(arena, seq_str));
        try out.appendSlice(arena, "  ");
        const time = core.view.timeString(entry.ts_ms, entry.tz_offset_min);
        try out.appendSlice(arena, try style.dim(arena, &time));
        if (entry.redacted) {
            try out.appendSlice(arena, try style.dim(arena, " [redacted]"));
            try out.append(arena, '\n');
            continue;
        }
        if (entry.edited) {
            try out.appendSlice(arena, try style.dim(arena, " (edited)"));
        }
        for (entry.tags) |tag| {
            try out.appendSlice(arena, try arena.print(" [{s}]", .{tag}));
        }
        try out.append(arena, ' ');
        try out.appendSlice(arena, entry.text);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

test "styled day view: off style is the frozen view; on style adds SGR only" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const work_tags = [_][]const u8{"work"};
    const entries = [_]core.view.ViewEntry{
        .{ .seq = 0, .ts_ms = 1_767_227_400_000, .tz_offset_min = 0, .day = 20454, .redacted = false, .edited = false, .text = "hello", .tags = &.{} },
        .{ .seq = 1, .ts_ms = 1_767_227_580_000, .tz_offset_min = 0, .day = 20455, .redacted = true, .edited = false, .text = "", .tags = &.{} },
        .{ .seq = 2, .ts_ms = 1_767_227_740_000, .tz_offset_min = 0, .day = 20455, .redacted = false, .edited = true, .text = "edited hello", .tags = &work_tags },
    };
    const range = core.view.DayRange{ .start = 20454, .end = 20456 };

    // Style off: byte-identical to the frozen view (core.view.renderRange
    // emits exactly these bytes for the same entries).
    const frozen = try renderStyledRange(allocator, output.Style.off, &entries, range);
    defer allocator.free(frozen);
    try std.testing.expectEqualStrings(
        "2026-01-01 Thu\n  0  00:30 hello\n\n2026-01-02 Fri\n  1  00:59 [redacted]\n  2  01:09 (edited) [work] edited hello\n",
        frozen,
    );

    // Style on: the same bytes wrapped in SGR — bold date, dim weekday,
    // accent seq, dim time and markers.
    const styled = try renderStyledRange(allocator, output.Style{ .enabled = true }, &entries, range);
    defer allocator.free(styled);
    const e = "\x1b[";
    try std.testing.expectEqualStrings(
        e ++ "1m2026-01-01" ++ e ++ "0m " ++ e ++ "2mThu" ++ e ++ "0m\n" ++
            "  " ++ e ++ "36m0" ++ e ++ "0m  " ++ e ++ "2m00:30" ++ e ++ "0m hello\n" ++
            "\n" ++ e ++ "1m2026-01-02" ++ e ++ "0m " ++ e ++ "2mFri" ++ e ++ "0m\n" ++
            "  " ++ e ++ "36m1" ++ e ++ "0m  " ++ e ++ "2m00:59" ++ e ++ "0m" ++ e ++ "2m [redacted]" ++ e ++ "0m\n" ++
            "  " ++ e ++ "36m2" ++ e ++ "0m  " ++ e ++ "2m01:09" ++ e ++ "0m" ++ e ++ "2m (edited)" ++ e ++ "0m [work] edited hello\n",
        styled,
    );

    // An empty range renders empty, styled or not.
    const empty = try renderStyledRange(allocator, output.Style{ .enabled = true }, &entries, .{ .start = 30000, .end = 30001 });
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
