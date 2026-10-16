//! zephyr profile — the derived profile plus the user's notes.md.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
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
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    const idx = try core.dstore.profileFresh(arena, &journal, &visible, result);
    defer idx.deinit();
    // Piped output (and $NO_COLOR) keeps the frozen contract bytes;
    // the TTY gets the styled stat sections.
    if (!style.enabled) {
        const doc = try core.dstore.renderProfileDisplay(arena, &journal, &visible, idx.entities);
        try output.printBlock(out, io, doc);
        return;
    }
    const stats = try core.derived.profileStats(arena, &visible, idx.entities);
    defer stats.deinit();
    const notes = try core.dstore.readNotesOrNull(arena, &journal);
    defer if (notes) |n| arena.free(n);
    const rendered = try table.renderProfile(arena, &stats, notes, style, table.terminalColumns(out));
    try output.printBlock(out, io, rendered);
}
