//! zephyr log [-t TAG]... "text" — and the bare-word quick log
//! (`zephyr <text>`; cli.zig dispatches it here, so the word itself is the
//! first part of the text). Prints `logged seq N`.

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
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    var parsed = try args.parseArgs(gpa, rest);
    defer parsed.deinit(gpa);
    const text = try args.joinParts(arena, parsed.parts.items);
    if (text.len == 0) {
        try output.printUsage(File.stderr(), io);
        return error.Usage;
    }
    const now_ms = cli_journal.nowMs(io);
    const journal = try core.journal.Journal.open(arena, io, environ_map, path, true);
    defer journal.close();
    // Verify before trust: never extend a failing journal.
    const pre = try journal.verify(arena);
    if (!pre.ok) {
        try output.reportIssue(File.stderr(), io, arena, pre.issue.?);
        return error.VerifyFailed;
    }
    const tz_offset_min = try journal.tzOffsetMinutesAtMs(now_ms);
    const seq = try journal.appendRecord(
        arena,
        core.records.RecordType.entry,
        0,
        text,
        parsed.tags.items,
        now_ms,
        tz_offset_min,
        false,
    );
    try output.printLine(File.stdout(), io, try arena.print("logged seq {d}", .{seq}));
}
