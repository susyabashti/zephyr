//! zephyr profile — the derived profile plus the user's notes.md.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
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
    no_pager: bool,
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path, false);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    const recs = try journal.collectPlaintext(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    const idx = try core.dstore.profileFresh(arena, &journal, &visible, result);
    defer idx.deinit();
    // Piped output (and $NO_COLOR) keeps the frozen contract bytes;
    // the TTY gets the styled stat sections. Long TTY output goes
    // through the pager in both cases (it never pages a non-TTY stream).
    const rendered = if (style.enabled) blk: {
        const stats = try core.derived.profileStats(arena, &visible, idx.entities);
        defer stats.deinit();
        const notes = try core.dstore.readNotesOrNull(arena, &journal);
        defer if (notes) |n| arena.free(n);
        break :blk try table.renderProfile(arena, &stats, notes, style, table.terminalColumns(out));
    } else blk: {
        break :blk try core.dstore.renderProfileDisplay(arena, &journal, &visible, idx.entities);
    };
    try pager.show(out, io, environ_map, path, no_pager, rendered);
}
