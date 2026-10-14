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
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    which: []const u8,
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, err_file, &journal);
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
    try renderJournalRange(arena, &journal, out, io, range);
}

pub fn runRangeView(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    range: core.view.DayRange,
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, err_file, &journal);
    try renderJournalRange(arena, &journal, out, io, range);
}

fn renderJournalRange(arena: Allocator, journal: *const core.journal.Journal, out: File, io: Io, range: core.view.DayRange) errors.RunError!void {
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const rendered = try core.view.renderRange(arena, recs.headers, recs.payloads, range);
    try output.printBlock(out, io, rendered);
}
