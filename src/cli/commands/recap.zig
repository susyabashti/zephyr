//! zephyr recap [start..end] — the period digest (default: the current
//! week, Mon-Sun); regenerates the digest artifact on demand.

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
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    if (rest.len > 1) return error.Usage;
    var range: ?core.view.DayRange = null;
    if (rest.len == 1) {
        range = args.parseDotDayRange(rest[0]) orelse return error.Usage;
    }
    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    if (range == null) range = try args.currentWeek(&journal);
    const digest = try core.dstore.digestOrRebuild(arena, &journal, &visible, range.?, result);
    try output.printBlock(out, io, digest);
}
