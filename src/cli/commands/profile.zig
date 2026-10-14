//! zephyr profile — the derived profile plus the user's notes.md.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
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
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    const doc = try core.dstore.profileWithNotes(arena, &journal, &visible, result);
    try output.printBlock(out, io, doc);
}
