//! zephyr recap [start..end] — the period digest (default: the current
//! week, Mon-Sun); regenerates the digest artifact on demand.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const args = @import("../args.zig");
const output = @import("../output.zig");
const pager = @import("../pager.zig");
const table = @import("../table.zig");
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
    no_pager: bool,
) errors.RunError!void {
    if (rest.len > 1) return error.Usage;
    var range: ?core.view.DayRange = null;
    if (rest.len == 1) {
        range = args.parseDotDayRange(rest[0]) orelse return error.Usage;
    }
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    if (range == null) range = try args.currentWeek(&journal);
    const stats = try core.dstore.digestStatsOrRebuild(arena, &journal, &visible, range.?, result);
    defer stats.deinit();
    // Piped output (and $NO_COLOR) keeps the frozen contract bytes;
    // the TTY gets the styled tables. Long TTY output goes through the
    // pager in both cases (it never pages a non-TTY stream).
    const rendered = if (style.enabled)
        try table.renderRecap(arena, &stats, range.?, style, table.terminalColumns(out))
    else
        try core.derived.renderDigestBodyFromStats(arena, &stats, range.?);
    try pager.show(out, io, environ_map, path, no_pager, rendered);
}
