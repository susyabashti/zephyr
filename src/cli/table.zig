//! The TTY presentation of the derived surfaces (`recap`, `profile`):
//! the terminal-width probe, the shared name/count/bar frequency table,
//! and the styled body renderers. These renderers are TTY-only — piped
//! output (and $NO_COLOR) never goes through them: the commands fall
//! back to the frozen core-rendered bytes, so the byte contracts
//! (spec/derived.md) stay untouched.

const std = @import("std");
const core = @import("zephyr_core");
const output = @import("output.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Style = output.Style;
const view = core.view;
const derived = core.derived;

/// The fixed width when the terminal size is unknown (plan section 13.7).
pub const FallbackWidth: usize = 72;

/// The styled renderers' errors: allocation and the civil-date math.
pub const RenderError = Allocator.Error || error{TimestampOutOfRange};

/// The terminal size of a sized stream, as reported by TIOCGWINSZ.
pub const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

/// The fixed row count when the terminal size is unknown: the pager's
/// page threshold (plan section 13.7).
pub const FallbackRows: u16 = 40;

fn ttySize(file: File, request: c_int) ?std.posix.winsize {
    var ws: std.posix.winsize = undefined;
    // Linux: the raw syscall — std.c requires an explicit libc dependency,
    // which core-only modules (such as the render tests) do not declare,
    // so linking it there is a compile error. macOS: C interop, resolved
    // from the system dynamic libraries.
    const ok: bool = switch (@import("builtin").os.tag) {
        .linux => std.os.linux.ioctl(file.handle, @as(u32, @bitCast(request)), @intFromPtr(&ws)) == 0,
        else => std.c.ioctl(file.handle, request, &ws) == 0,
    };
    if (ok and ws.row > 0 and ws.col > 0) return ws;
    return null;
}

/// The terminal size of `file` (TIOCGWINSZ), or null when the stream is
/// not a sized terminal. The request code is defined differently per OS:
/// macOS `_IOR('t', 104, struct winsize)`, Linux the fixed number.
pub fn terminalSize(file: File) ?TerminalSize {
    const ws = switch (@import("builtin").os.tag) {
        .macos => ttySize(file, 0x40087468),
        .linux => ttySize(file, 0x5413),
        else => null,
    } orelse return null;
    return .{ .rows = ws.row, .cols = ws.col };
}

/// The terminal column count of `file`, or FallbackWidth when the stream
/// is not a sized terminal.
pub fn terminalColumns(file: File) usize {
    return if (terminalSize(file)) |s| s.cols else FallbackWidth;
}

/// The terminal row count of `file`, or FallbackRows when the stream is
/// not a sized terminal. The pager pages output taller than this.
pub fn terminalRows(file: File) u16 {
    return if (terminalSize(file)) |s| s.rows else FallbackRows;
}

/// The number of `█` blocks for `count` against the table's `max_count`:
/// 0 for a zero count, proportional otherwise — at most 8, at least 1.
fn barBlocks(count: u32, max_count: u32) u8 {
    if (count == 0) return 0;
    if (max_count == 0) return 1;
    return @intCast(@max(1, (count * 8) / max_count));
}

/// Eight `█` (U+2588, three bytes each); `barString(n)` slices it.
const BarFull: [24]u8 = blk: {
    var buf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < 24) : (i += 1) buf[i] = "█"[i % 3];
    break :blk buf;
};

fn barString(blocks: u8) []const u8 {
    return BarFull[0 .. blocks * 3];
}

/// One frequency table (plan section 13.3.1): each row is
/// `  NAME COUNT  BAR` — the name left-aligned in a column padded to the
/// widest name, the count right-aligned in a fixed 3-wide column (dim),
/// then, when even the longest bar fits the terminal width, two spaces
/// and a soft green `█` bar proportional to the table's max count. A zero
/// count renders a dim `0` with no bar. Tag names render yellow.
fn frequencyTable(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    style: Style,
    width: usize,
    rows: []const derived.TagCount,
    yellow_names: bool,
) Allocator.Error!void {
    var widest: usize = 0;
    var max_count: u32 = 0;
    for (rows) |row| {
        widest = @max(widest, row.name.len);
        max_count = @max(max_count, row.count);
    }
    // 2 indent + name column + 1 gap + 3 count + 2 gap + 8 (a full bar).
    const with_bar = 2 + widest + 1 + 3 + 2 + 8 <= width;
    for (rows) |row| {
        const name = if (yellow_names) try style.warn(allocator, row.name) else row.name;
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, name);
        var pad = widest - row.name.len;
        while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
        try out.append(allocator, ' ');
        var cbuf: [16]u8 = undefined; // u32 decimal, at most 10 digits
        const count_str = std.fmt.bufPrint(&cbuf, "{d:>3}", .{row.count}) catch unreachable;
        try out.appendSlice(allocator, try style.dim(allocator, count_str));
        const blocks = barBlocks(row.count, max_count);
        if (with_bar and blocks > 0) {
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, try style.bar(allocator, barString(blocks)));
        }
        try out.append(allocator, '\n');
    }
}

/// A name list: one name per line, indented two spaces, default weight.
fn nameList(allocator: Allocator, out: *std.ArrayList(u8), rows: []const derived.TagCount) Allocator.Error!void {
    for (rows) |row| {
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, row.name);
        try out.append(allocator, '\n');
    }
}

/// A titled table section: a blank line, the blue bold title, the table.
fn tableSection(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    style: Style,
    width: usize,
    title: []const u8,
    rows: []const derived.TagCount,
    yellow_names: bool,
) Allocator.Error!void {
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, try style.title(allocator, title));
    try out.append(allocator, '\n');
    try frequencyTable(allocator, out, style, width, rows, yellow_names);
}

/// A titled name-list section: a blank line, the blue bold title, the
/// names.
fn listSection(allocator: Allocator, out: *std.ArrayList(u8), style: Style, title: []const u8, rows: []const derived.TagCount) Allocator.Error!void {
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, try style.title(allocator, title));
    try out.append(allocator, '\n');
    try nameList(allocator, out, rows);
}

/// A scalar stat section: a blank line, the blue bold title, the value
/// indented two spaces.
fn scalarSection(allocator: Allocator, out: *std.ArrayList(u8), style: Style, title: []const u8, value: []const u8) Allocator.Error!void {
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, try style.title(allocator, title));
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, value);
    try out.append(allocator, '\n');
}

/// An empty list stat section: a blank line, the blue bold title, and a
/// dim em dash (U+2014) indented two spaces — the contract's empty glyph.
fn emptySection(allocator: Allocator, out: *std.ArrayList(u8), style: Style, title: []const u8) Allocator.Error!void {
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, try style.title(allocator, title));
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, try style.dim(allocator, "\u{2014}"));
    try out.append(allocator, '\n');
}

/// The styled recap body (TTY only): the bold period line, then one
/// section per stat — `Top words` (top 10) and `Tags` (yellow names) as
/// frequency tables, `Activity` as a per-day table (zero days a dim `0`,
/// no bar), and `People and places` as a name list. Absent sections are
/// omitted entirely. The caller keeps the stats; this function owns the
/// returned text.
pub fn renderRecap(
    allocator: Allocator,
    stats: *const derived.DigestStats,
    range: view.DayRange,
    style: Style,
    width: usize,
) RenderError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const d0 = view.civilDate(range.start) catch return error.TimestampOutOfRange;
    const d1 = view.civilDate(range.end - 1) catch return error.TimestampOutOfRange;
    var pbuf: [64]u8 = undefined;
    const period = std.fmt.bufPrint(&pbuf, "{d:0>4}-{d:0>2}-{d:0>2} \u{2013} {d:0>4}-{d:0>2}-{d:0>2} \u{B7} {d} {s}", .{
        d0.year, d0.month, d0.day, d1.year, d1.month, d1.day, stats.n, view.countNoun(stats.n, "entry", "entries"),
    }) catch unreachable;
    try out.appendSlice(allocator, try style.bold(allocator, period));
    if (stats.redacted > 0) {
        const note = try allocator.print(" ({d} redacted)", .{stats.redacted});
        defer allocator.free(note);
        try out.appendSlice(allocator, try style.dim(allocator, note));
    }
    try out.append(allocator, '\n');
    if (stats.n > 0) {
        if (stats.words.len > 0) {
            try tableSection(allocator, &out, style, width, "Top words", stats.words[0..@min(10, stats.words.len)], false);
        }
        if (stats.tags.len > 0) {
            try tableSection(allocator, &out, style, width, "Tags", stats.tags, true);
        }
        try activitySection(allocator, &out, style, width, stats, range);
        if (stats.places.len > 0) {
            try listSection(allocator, &out, style, "People and places", stats.places);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// The `Activity` section: one row per day of the period — the same
/// 14-day window as the piped contract — then the dim more-days note.
fn activitySection(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    style: Style,
    width: usize,
    stats: *const derived.DigestStats,
    range: view.DayRange,
) RenderError!void {
    const n_days: i64 = range.end - range.start;
    const shown: i64 = @min(14, n_days);
    var date_bufs: [14][10]u8 = undefined;
    var rows: [14]derived.TagCount = undefined;
    var count: usize = 0;
    var ptr: usize = 0;
    var d: i64 = range.start;
    while (d < range.start + shown) : (d += 1) {
        // stats.days is ascending: advance past earlier days, count the
        // equals.
        while (ptr < stats.days.len and stats.days[ptr] < d) ptr += 1;
        var c: u32 = 0;
        while (ptr < stats.days.len and stats.days[ptr] == d) {
            c += 1;
            ptr += 1;
        }
        const cd = view.civilDate(d) catch return error.TimestampOutOfRange;
        const ds = std.fmt.bufPrint(&date_bufs[count], "{d:0>4}-{d:0>2}-{d:0>2}", .{ cd.year, cd.month, cd.day }) catch unreachable;
        rows[count] = .{ .name = ds, .count = c };
        count += 1;
    }
    try tableSection(allocator, out, style, width, "Activity", rows[0..count], false);
    if (n_days > 14) {
        const more = @as(u64, @intCast(n_days - 14));
        const note = try allocator.print("  \u{2026} {d} more {s}", .{ more, view.countNoun(more, "day", "days") });
        defer allocator.free(note);
        try out.appendSlice(allocator, try style.dim(allocator, note));
        try out.append(allocator, '\n');
    }
}

/// The notes.md file's lines, each non-empty line indented two spaces —
/// the piped contract's presentation (spec/derived.md section 6), at
/// default weight.
fn notesLines(allocator: Allocator, out: *std.ArrayList(u8), notes: []const u8) Allocator.Error!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= notes.len) : (i += 1) {
        if (i == notes.len or notes[i] == '\n') {
            if (i > start) {
                try out.appendSlice(allocator, "  ");
                try out.appendSlice(allocator, notes[start..i]);
            }
            if (i < notes.len) try out.append(allocator, '\n');
            start = i + 1;
        }
    }
}

/// The styled profile body (TTY only): the bold span line, then one
/// section per stat — the scalar stats one indented value, `Tags` a
/// frequency table (yellow names), `People and places` a name list, an
/// empty list a dim em dash. With `notes` (the notes.md bytes), the
/// user's notes come first under a `Notes` title, a blank line, and
/// `About you`; the stats block follows at column 0. The caller keeps
/// the stats and the notes; this function owns the returned text.
pub fn renderProfile(
    allocator: Allocator,
    stats: *const derived.ProfileStats,
    notes: ?[]const u8,
    style: Style,
    width: usize,
) RenderError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (notes) |n| {
        try out.appendSlice(allocator, try style.title(allocator, "Notes"));
        try out.append(allocator, '\n');
        try notesLines(allocator, &out, n);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, try style.title(allocator, "About you"));
        try out.append(allocator, '\n');
    }
    if (stats.n == 0) {
        try out.appendSlice(allocator, try style.bold(allocator, "0 entries"));
        try out.append(allocator, '\n');
        return out.toOwnedSlice(allocator);
    }
    const first = view.civilDate(stats.first_day.?) catch return error.TimestampOutOfRange;
    var sbuf: [48]u8 = undefined;
    const span = std.fmt.bufPrint(&sbuf, "{d} {s} \u{B7} {d:0>4}-{d:0>2}-{d:0>2} onward", .{
        stats.n, view.countNoun(stats.n, "entry", "entries"), first.year, first.month, first.day,
    }) catch unreachable;
    try out.appendSlice(allocator, try style.bold(allocator, span));
    if (stats.redacted > 0) {
        const note = try allocator.print(" ({d} redacted)", .{stats.redacted});
        defer allocator.free(note);
        try out.appendSlice(allocator, try style.dim(allocator, note));
    }
    try out.append(allocator, '\n');
    var vbuf: [24]u8 = undefined;
    const month = std.fmt.bufPrint(&vbuf, "{d:0>4}-{d:0>2}", .{
        @as(u64, @intCast(@divTrunc(stats.month.?, 12))), @as(u64, @intCast(@mod(stats.month.?, 12))) + 1,
    }) catch unreachable;
    try scalarSection(allocator, &out, style, "Most active", month);
    try scalarSection(allocator, &out, style, "Weekday", view.Weekdays[stats.weekday.?]);
    const bands = [_][]const u8{ "morning", "afternoon", "evening", "night" };
    try scalarSection(allocator, &out, style, "Time of day", bands[stats.band.?]);
    const streak_v = std.fmt.bufPrint(&vbuf, "{d} {s}", .{ stats.streak, view.countNoun(stats.streak, "day", "days") }) catch unreachable;
    try scalarSection(allocator, &out, style, "Streak", streak_v);
    const avg_v = std.fmt.bufPrint(&vbuf, "{d}", .{stats.avg_words}) catch unreachable;
    try scalarSection(allocator, &out, style, "Avg words", avg_v);
    if (stats.tags.len > 0) {
        try tableSection(allocator, &out, style, width, "Tags", stats.tags, true);
    } else {
        try emptySection(allocator, &out, style, "Tags");
    }
    if (stats.places.len > 0) {
        try listSection(allocator, &out, style, "People and places", stats.places);
    } else {
        try emptySection(allocator, &out, style, "People and places");
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- tests

const E = "\x1b[";
const ON = Style{ .enabled = true };

/// The shared recap fixture: one week (Mon 2026-10-12 .. 2026-10-18),
/// three entries on Thu and Fri, two tags, six top words, one place.
fn recapStats() derived.DigestStats {
    const allocator = std.testing.allocator;
    return derived.DigestStats{
        .n = 3,
        .redacted = 0,
        .min_seq = 0,
        .max_seq = 2,
        .tags = &.{ .{ .name = "zephyr", .count = 2 }, .{ .name = "ci", .count = 1 } },
        .words = &.{
            .{ .name = "qwen", .count = 2 },
            .{ .name = "ai", .count = 1 },
            .{ .name = "model", .count = 1 },
            .{ .name = "plan", .count = 1 },
            .{ .name = "released", .count = 1 },
            .{ .name = "zig", .count = 1 },
        },
        .days = &[_]i64{ 20741, 20742, 20742 }, // Thu, Fri, Fri
        .places = &.{.{ .name = "LLMs", .count = 1 }},
        .allocator = allocator,
    };
}

const recapRange = view.DayRange{ .start = 20738, .end = 20745 };

test "recap TTY: exact SGR layout at width 72" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stats = recapStats();
    const got = try renderRecap(allocator, &stats, recapRange, ON, 72);
    defer allocator.free(got);
    const want =
        E ++ "1m2026-10-12 \u{2013} 2026-10-18 \u{B7} 3 entries" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mTop words" ++ E ++ "0m\n" ++
        "  qwen     " ++ E ++ "2m  2" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  ai       " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  model    " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  plan     " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  released " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  zig      " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mTags" ++ E ++ "0m\n" ++
        "  " ++ E ++ "33mzephyr" ++ E ++ "0m " ++ E ++ "2m  2" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  " ++ E ++ "33mci" ++ E ++ "0m     " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mActivity" ++ E ++ "0m\n" ++
        "  2026-10-12 " ++ E ++ "2m  0" ++ E ++ "0m\n" ++
        "  2026-10-13 " ++ E ++ "2m  0" ++ E ++ "0m\n" ++
        "  2026-10-14 " ++ E ++ "2m  0" ++ E ++ "0m\n" ++
        "  2026-10-15 " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  2026-10-16 " ++ E ++ "2m  2" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  2026-10-17 " ++ E ++ "2m  0" ++ E ++ "0m\n" ++
        "  2026-10-18 " ++ E ++ "2m  0" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mPeople and places" ++ E ++ "0m\n" ++
        "  LLMs\n";
    try std.testing.expectEqualStrings(want, got);
}

test "recap TTY: an empty period renders the bold period line alone" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stats = derived.DigestStats{
        .n = 0,
        .redacted = 0,
        .min_seq = 0,
        .max_seq = 0,
        .tags = &.{},
        .words = &.{},
        .days = &.{},
        .places = &.{},
        .allocator = allocator,
    };
    const got = try renderRecap(allocator, &stats, .{ .start = 20485, .end = 20486 }, ON, 72);
    defer allocator.free(got);
    try std.testing.expectEqualStrings(E ++ "1m2026-02-01 \u{2013} 2026-02-01 \u{B7} 0 entries" ++ E ++ "0m\n", got);
}

test "frequency table: the bar and its gap drop when the widest row would not fit" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rows = [_]derived.TagCount{ .{ .name = "ab", .count = 2 }, .{ .name = "c", .count = 1 } };

    // 2 + 2 + 1 + 3 + 2 + 8 = 18: at width 17 the bar is dropped, at 18
    // it fits.
    var out17 = std.ArrayList(u8).empty;
    defer out17.deinit(allocator);
    try frequencyTable(allocator, &out17, ON, 17, &rows, false);
    try std.testing.expectEqualStrings(
        "  ab " ++ E ++ "2m  2" ++ E ++ "0m\n" ++ "  c  " ++ E ++ "2m  1" ++ E ++ "0m\n",
        out17.items,
    );

    var out18 = std.ArrayList(u8).empty;
    defer out18.deinit(allocator);
    try frequencyTable(allocator, &out18, ON, 18, &rows, false);
    try std.testing.expectEqualStrings(
        "  ab " ++ E ++ "2m  2" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
            "  c  " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n",
        out18.items,
    );
}

test "bar blocks: proportional, at most 8, at least 1, zero stays zero" {
    try std.testing.expectEqual(@as(u8, 0), barBlocks(0, 5));
    try std.testing.expectEqual(@as(u8, 8), barBlocks(1, 1));
    try std.testing.expectEqual(@as(u8, 8), barBlocks(2, 2));
    try std.testing.expectEqual(@as(u8, 4), barBlocks(1, 2));
    try std.testing.expectEqual(@as(u8, 1), barBlocks(1, 10));
    try std.testing.expectEqual(@as(u8, 2), barBlocks(3, 10));
    try std.testing.expectEqual(@as(u8, 8), barBlocks(10, 10));
}

/// The shared profile fixture: three entries from 2026-01-01 (a
/// Thursday), one redacted, fullest month 2026-01, weekday Thu, band
/// evening, a 2-day streak.
fn profileStats() derived.ProfileStats {
    const allocator = std.testing.allocator;
    return derived.ProfileStats{
        .n = 3,
        .redacted = 1,
        .first_day = 20454, // 2026-01-01
        .month = 2026 * 12 + 0,
        .weekday = 3, // Thu
        .band = 2, // evening
        .streak = 2,
        .avg_words = 41,
        .tags = &.{ .{ .name = "zephyr", .count = 2 }, .{ .name = "ci", .count = 1 } },
        .places = &.{.{ .name = "LLMs", .count = 1 }},
        .allocator = allocator,
    };
}

test "profile TTY: exact SGR layout at width 72" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stats = profileStats();
    const got = try renderProfile(allocator, &stats, null, ON, 72);
    defer allocator.free(got);
    const want =
        E ++ "1m3 entries \u{B7} 2026-01-01 onward" ++ E ++ "0m" ++ E ++ "2m (1 redacted)" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mMost active" ++ E ++ "0m\n" ++
        "  2026-01\n" ++
        "\n" ++
        E ++ "1;34mWeekday" ++ E ++ "0m\n" ++
        "  Thu\n" ++
        "\n" ++
        E ++ "1;34mTime of day" ++ E ++ "0m\n" ++
        "  evening\n" ++
        "\n" ++
        E ++ "1;34mStreak" ++ E ++ "0m\n" ++
        "  2 days\n" ++
        "\n" ++
        E ++ "1;34mAvg words" ++ E ++ "0m\n" ++
        "  41\n" ++
        "\n" ++
        E ++ "1;34mTags" ++ E ++ "0m\n" ++
        "  " ++ E ++ "33mzephyr" ++ E ++ "0m " ++ E ++ "2m  2" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "  " ++ E ++ "33mci" ++ E ++ "0m     " ++ E ++ "2m  1" ++ E ++ "0m  " ++ E ++ "2;32m\u{2588}\u{2588}\u{2588}\u{2588}" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mPeople and places" ++ E ++ "0m\n" ++
        "  LLMs\n";
    try std.testing.expectEqualStrings(want, got);
}

test "profile TTY: notes first, then the stats block under About you" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var empty = profileStats();
    empty.n = 0;
    empty.redacted = 0;
    empty.first_day = null;
    empty.month = null;
    empty.weekday = null;
    empty.band = null;
    empty.streak = 0;
    empty.avg_words = 0;
    empty.tags = &.{};
    empty.places = &.{};
    const notes = "I like tea.\nKeep it local.\n";
    const got = try renderProfile(allocator, &empty, notes, ON, 72);
    defer allocator.free(got);
    const want =
        E ++ "1;34mNotes" ++ E ++ "0m\n" ++
        "  I like tea.\n" ++
        "  Keep it local.\n" ++
        "\n" ++
        E ++ "1;34mAbout you" ++ E ++ "0m\n" ++
        E ++ "1m0 entries" ++ E ++ "0m\n";
    try std.testing.expectEqualStrings(want, got);
}

test "profile TTY: empty lists render a dim em dash" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stats = profileStats();
    stats.n = 1;
    stats.redacted = 0;
    stats.weekday = 3;
    stats.band = 0; // morning
    stats.streak = 1;
    stats.avg_words = 2;
    stats.tags = &.{};
    stats.places = &.{};
    const got = try renderProfile(allocator, &stats, null, ON, 72);
    defer allocator.free(got);
    const want =
        E ++ "1m1 entry \u{B7} 2026-01-01 onward" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mMost active" ++ E ++ "0m\n" ++
        "  2026-01\n" ++
        "\n" ++
        E ++ "1;34mWeekday" ++ E ++ "0m\n" ++
        "  Thu\n" ++
        "\n" ++
        E ++ "1;34mTime of day" ++ E ++ "0m\n" ++
        "  morning\n" ++
        "\n" ++
        E ++ "1;34mStreak" ++ E ++ "0m\n" ++
        "  1 day\n" ++
        "\n" ++
        E ++ "1;34mAvg words" ++ E ++ "0m\n" ++
        "  2\n" ++
        "\n" ++
        E ++ "1;34mTags" ++ E ++ "0m\n" ++
        "  " ++ E ++ "2m\u{2014}" ++ E ++ "0m\n" ++
        "\n" ++
        E ++ "1;34mPeople and places" ++ E ++ "0m\n" ++
        "  " ++ E ++ "2m\u{2014}" ++ E ++ "0m\n";
    try std.testing.expectEqualStrings(want, got);
}
