//! zephyr export --for-ai [range] — the LLM view of the log; refuses a
//! failing log. range: YYYY-MM-DD or YYYY-MM-DD:YYYY-MM-DD (inclusive).

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
    // export --for-ai [YYYY-MM-DD[:YYYY-MM-DD]]
    if (rest.len < 1 or rest.len > 2 or !std.mem.eql(u8, rest[0], "--for-ai")) {
        try output.printUsage(File.stderr(), io);
        return error.Usage;
    }
    var range: ?core.view.DayRange = null;
    if (rest.len == 2) {
        range = args.parseDayRange(rest[1]) orelse {
            try output.printUsage(File.stderr(), io);
            return error.Usage;
        };
    }
    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const rendered = core.exporter.render(arena, &journal, range) catch |err| switch (err) {
        // Refused before rendering; re-verify only to report the position.
        error.VerifyFailed => {
            const result = try journal.verify(arena);
            try output.reportIssue(err_file, io, arena, result.issue.?);
            return error.VerifyFailed;
        },
        else => return err,
    };
    try output.printBlock(out, io, rendered);
}
