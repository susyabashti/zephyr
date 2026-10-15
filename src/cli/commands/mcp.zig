//! zephyr mcp [--allow-write] — the read-only MCP (AI) server
//! (spec/mcp.md). stdin/stdout are the protocol channel; the journal must
//! exist unless --allow-write is set (then a fresh journal is created).

const std = @import("std");
const core = @import("zephyr_core");
const mcp = @import("zephyr_mcp");
const errors = @import("../errors.zig");
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
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    var allow_write = false;
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--allow-write")) {
            allow_write = true;
        } else {
            try output.printUsage(err_file, io);
            return error.Usage;
        }
    }
    const journal = if (allow_write)
        try core.journal.Journal.open(arena, io, environ_map, path, true)
    else
        try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    var server = mcp.server.Server.init(&journal, allow_write);
    return server.run(arena, io);
}
