//! zephyr today | yesterday | week | on YYYY-MM-DD — render the journal's
//! visible entries for a period (local civil days under the journal's
//! timezone).

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
const pager = @import("../pager.zig");
const table = @import("../table.zig");
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
    no_pager: bool,
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
    try renderJournalRange(arena, &journal, style, out, io, environ_map, path, no_pager, range);
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
    no_pager: bool,
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    try renderJournalRange(arena, &journal, style, out, io, environ_map, path, no_pager, range);
}

fn renderJournalRange(
    arena: Allocator,
    journal: *const core.journal.Journal,
    style: output.Style,
    out: File,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    data_dir: []const u8,
    no_pager: bool,
    range: core.view.DayRange,
) errors.RunError!void {
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    // The civil day, for the (today) marker on the day rule.
    const now_ms = cli_journal.nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const today = try core.view.localDay(now_ms, offset);
    // The styled TTY view; piped output (and $NO_COLOR) keeps the frozen
    // bytes from core.view.renderRange, untouched. Long TTY output goes
    // through the pager in both cases (it never pages a non-TTY stream).
    const rendered = if (style.enabled) blk: {
        const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
        defer visible.deinit();
        break :blk try renderStyledRange(arena, style, visible.entries, range, today, table.terminalSize(out));
    } else try core.view.renderRange(arena, recs.headers, recs.payloads, range);
    try pager.show(out, io, environ_map, data_dir, no_pager, rendered);
}

/// The styled day view (TTY only). One `== DATE Www (today) ====…` rule
/// per day (blue date, dim weekday and `=` fill to the terminal width), a
/// blank line between days, entry lines `  SEQ  HH:MM …` — with the seq
/// accented (the handle for edit/rm/redact, the same cyan as the ✓ lines),
/// the time dimmed, the tags yellow, and the text at full weight,
/// word-wrapped to the terminal width. With styling off every helper
/// returns its input unchanged, so the bytes are the frozen view
/// (core.view.renderRange).
fn renderStyledRange(
    arena: Allocator,
    style: output.Style,
    entries: []const core.view.ViewEntry,
    range: core.view.DayRange,
    today: i64,
    size: ?table.TerminalSize,
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
            if (style.enabled) {
                const width = if (size) |s| s.cols else table.FallbackWidth;
                try out.appendSlice(arena, try output.dayRule(arena, style, date_str, core.view.weekdayName(entry.day), entry.day == today, width));
                try out.append(arena, '\n');
            } else {
                try out.appendSlice(arena, try style.bold(arena, date_str));
                try out.append(arena, ' ');
                try out.appendSlice(arena, try style.dim(arena, core.view.weekdayName(entry.day)));
                try out.append(arena, '\n');
            }
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
        // The display column the text starts in: what precedes it, for the
        // wrap's continuation indent.
        var text_col: usize = 2 + seq_str.len + 2 + time.len + 1;
        if (entry.edited) {
            try out.appendSlice(arena, try style.dim(arena, " (edited)"));
            text_col += " (edited)".len;
        }
        for (entry.tags) |tag| {
            const bracketed = try arena.print(" [{s}]", .{tag});
            defer arena.free(bracketed);
            try out.appendSlice(arena, try style.warn(arena, bracketed));
            text_col += bracketed.len;
        }
        try out.append(arena, ' ');
        var text = entry.text;
        if (style.enabled) {
            if (size) |s| {
                if (s.cols > text_col) {
                    text = try output.wrapText(arena, entry.text, s.cols, text_col);
                }
            }
        }
        try out.appendSlice(arena, text);
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
        .{ .seq = 1, .ts_ms = 1_767_315_540_000, .tz_offset_min = 0, .day = 20455, .redacted = true, .edited = false, .text = "", .tags = &.{} },
        .{ .seq = 2, .ts_ms = 1_767_316_140_000, .tz_offset_min = 0, .day = 20455, .redacted = false, .edited = true, .text = "edited hello", .tags = &work_tags },
    };
    const range = core.view.DayRange{ .start = 20454, .end = 20456 };

    // Style off: byte-identical to the frozen view (core.view.renderRange
    // emits exactly these bytes for the same entries).
    const frozen = try renderStyledRange(allocator, output.Style.off, &entries, range, 20453, null);
    defer allocator.free(frozen);
    try std.testing.expectEqualStrings(
        "2026-01-01 Thu\n  0  00:30 hello\n\n2026-01-02 Fri\n  1  00:59 [redacted]\n  2  01:09 (edited) [work] edited hello\n",
        frozen,
    );

    // Style on: the day rule (== DATE Www ====…, the `=` fill to the 72
    // fallback width — the terminal size is unknown here), yellow tags,
    // and the accent seq, dim time and (edited) marker. The fill is built
    // in a loop: ++ concatenation is comptime-only.
    const styled = try renderStyledRange(allocator, output.Style{ .enabled = true }, &entries, range, 20453, null);
    defer allocator.free(styled);
    const e = "\x1b[";
    var eq55 = std.ArrayList(u8).empty; // 72 - ("== " ++ "2026-01-01" ++ " " ++ "Thu").len
    defer eq55.deinit(allocator);
    for (0..55) |_| try eq55.append(allocator, '=');
    const eqs = eq55.items;
    var want = std.ArrayList(u8).empty;
    defer want.deinit(allocator);
    try want.appendSlice(allocator, "== " ++ e ++ "1;34m2026-01-01" ++ e ++ "0m " ++ e ++ "2mThu" ++ e ++ "0m" ++ e ++ "2m");
    try want.appendSlice(allocator, eqs);
    try want.appendSlice(allocator, e ++ "0m\n" ++
        "  " ++ e ++ "36m0" ++ e ++ "0m  " ++ e ++ "2m00:30" ++ e ++ "0m hello\n" ++
        "\n");
    try want.appendSlice(allocator, "== " ++ e ++ "1;34m2026-01-02" ++ e ++ "0m " ++ e ++ "2mFri" ++ e ++ "0m" ++ e ++ "2m");
    try want.appendSlice(allocator, eqs);
    try want.appendSlice(allocator, e ++ "0m\n" ++
        "  " ++ e ++ "36m1" ++ e ++ "0m  " ++ e ++ "2m00:59" ++ e ++ "0m" ++ e ++ "2m [redacted]" ++ e ++ "0m\n" ++
        "  " ++ e ++ "36m2" ++ e ++ "0m  " ++ e ++ "2m01:09" ++ e ++ "0m" ++ e ++ "2m (edited)" ++ e ++ "0m" ++ e ++ "33m [work]" ++ e ++ "0m edited hello\n");
    try std.testing.expectEqualSlices(u8, want.items, styled);

    // An empty range renders empty, styled or not.
    const empty = try renderStyledRange(allocator, output.Style{ .enabled = true }, &entries, .{ .start = 30000, .end = 30001 }, 20453, null);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "styled day view: the (today) marker and TTY wrapping at width 36" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]core.view.ViewEntry{
        .{ .seq = 0, .ts_ms = 1_767_227_400_000, .tz_offset_min = 0, .day = 20454, .redacted = false, .edited = false, .text = "the quick brown fox jumps over the lazy dog", .tags = &.{} },
    };
    const range = core.view.DayRange{ .start = 20454, .end = 20455 };
    // The entry's day is today: the rule carries the marker, and the
    // text (25 columns available) wraps after "jumps". The fill is built
    // in a loop: ++ concatenation is comptime-only.
    const got = try renderStyledRange(allocator, output.Style{ .enabled = true }, &entries, range, 20454, .{ .rows = 10, .cols = 36 });
    defer allocator.free(got);
    const e = "\x1b[";
    var eq11 = std.ArrayList(u8).empty; // 36 - ("== " ++ "2026-01-01" ++ " " ++ "Thu" ++ " (today)").len
    defer eq11.deinit(allocator);
    for (0..11) |_| try eq11.append(allocator, '=');
    const eqs = eq11.items;
    var want = std.ArrayList(u8).empty;
    defer want.deinit(allocator);
    try want.appendSlice(allocator, "== " ++ e ++ "1;34m2026-01-01" ++ e ++ "0m " ++ e ++ "2mThu" ++ e ++ "0m" ++ e ++ "2m (today)" ++ e ++ "0m" ++ e ++ "2m");
    try want.appendSlice(allocator, eqs);
    try want.appendSlice(allocator, e ++ "0m\n" ++
        "  " ++ e ++ "36m0" ++ e ++ "0m  " ++ e ++ "2m00:30" ++ e ++ "0m the quick brown fox jumps\n" ++
        "           over the lazy dog\n");
    try std.testing.expectEqualSlices(u8, want.items, got);
}
