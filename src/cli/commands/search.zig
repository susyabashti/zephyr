//! zephyr search <query...> — keyword search over the visible entries.
//! On a TTY the seq is accented, the date bold, the time dimmed, the
//! tags yellow.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const args = @import("../args.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn run(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    const query = try args.joinParts(arena, rest);
    if (query.len == 0) return error.Usage;
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    const matches = try core.search.find(arena, &visible, query);
    defer arena.free(matches);
    // The styled TTY view; piped output (and $NO_COLOR) keeps the frozen
    // bytes from core.search.render, untouched.
    const rendered = if (style.enabled)
        try renderStyled(arena, style, matches, query)
    else
        try core.search.render(arena, matches, query);
    try output.printBlock(out, io, rendered);
}

/// The styled search view (TTY only). The same bytes as
/// core.search.render: the count label, a blank line, then one line per
/// match — with the seq accented (the handle for edit/rm/redact, the same
/// cyan as the ✓ lines), the date bold, the time dimmed, and the tag
/// block yellow; the text at full weight.
fn renderStyled(
    arena: Allocator,
    style: output.Style,
    matches: []const core.search.Match,
    query: []const u8,
) core.search.RenderError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(arena);
    var label_buf: [1 << 16]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{d} {s} for \"{s}\"", .{
        matches.len, output.countNoun(matches.len, "match", "matches"), query,
    }) catch unreachable;
    try out.appendSlice(arena, label);
    try out.append(arena, '\n');
    if (matches.len > 0) {
        try out.append(arena, '\n');
        var seq_buf: [20]u8 = undefined; // u64 decimal
        var date_buf: [16]u8 = undefined;
        for (matches) |m| {
            const date = core.view.civilDate(m.day) catch return error.TimestampOutOfRange;
            const time = core.view.timeString(m.ts_ms, m.tz_offset_min);
            const seq_str = std.fmt.bufPrint(&seq_buf, "{d}", .{m.seq}) catch unreachable;
            const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ date.year, date.month, date.day }) catch unreachable;
            try out.appendSlice(arena, try style.accent(arena, seq_str));
            try out.appendSlice(arena, "  ");
            try out.appendSlice(arena, try style.bold(arena, date_str));
            try out.append(arena, ' ');
            try out.appendSlice(arena, try style.dim(arena, &time));
            try out.appendSlice(arena, "  ");
            for (m.tags) |tag| {
                const bracketed = try arena.print("[{s}]", .{tag});
                defer arena.free(bracketed);
                try out.appendSlice(arena, try style.warn(arena, bracketed));
            }
            if (m.tags.len > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, m.text);
            try out.append(arena, '\n');
        }
    }
    return out.toOwnedSlice(arena);
}

test "styled search: off style is the frozen render; on style adds SGR only" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const work_tags = [_][]const u8{"work"};
    const matches = [_]core.search.Match{
        .{ .seq = 0, .day = 20454, .ts_ms = 1_767_225_600_000, .tz_offset_min = 0, .text = "bought milk", .tags = &.{} },
        .{ .seq = 1, .day = 20454, .ts_ms = 1_767_225_660_000, .tz_offset_min = 0, .text = "walked the dog", .tags = &work_tags },
    };

    // Style off: byte-identical to the frozen render (core.search.render
    // emits exactly these bytes for the same matches).
    const frozen = try renderStyled(allocator, output.Style.off, &matches, "milk");
    defer allocator.free(frozen);
    try std.testing.expectEqualStrings(
        "2 matches for \"milk\"\n\n0  2026-01-01 00:00  bought milk\n1  2026-01-01 00:01  [work] walked the dog\n",
        frozen,
    );

    const none = [_]core.search.Match{};
    const frozen_none = try renderStyled(allocator, output.Style.off, &none, "zebra");
    defer allocator.free(frozen_none);
    try std.testing.expectEqualStrings("0 matches for \"zebra\"\n", frozen_none);

    // Style on: the same bytes wrapped in SGR — accent seq, bold date,
    // dim time, yellow tag block; the text stays at full weight.
    const styled = try renderStyled(allocator, output.Style{ .enabled = true }, &matches, "milk");
    defer allocator.free(styled);
    const e = "\x1b[";
    try std.testing.expectEqualStrings(
        "2 matches for \"milk\"\n\n" ++
            e ++ "36m0" ++ e ++ "0m  " ++ e ++ "1m2026-01-01" ++ e ++ "0m " ++ e ++ "2m00:00" ++ e ++ "0m  bought milk\n" ++
            e ++ "36m1" ++ e ++ "0m  " ++ e ++ "1m2026-01-01" ++ e ++ "0m " ++ e ++ "2m00:01" ++ e ++ "0m  " ++ e ++ "33m[work]" ++ e ++ "0m walked the dog\n",
        styled,
    );
}
