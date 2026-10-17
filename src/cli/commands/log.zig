//! zephyr log [-t TAG]... "text" — and the bare-word quick log
//! (`zephyr <text>`; cli.zig dispatches it here, so the word itself is the
//! first part of the text). With no text on a TTY, the editor is opened on
//! an empty buffer instead — `zephyr` with no args is the same (cli.zig
//! dispatches it here with an empty rest). Prints `✓ logged seq N`
//! (styled on a TTY).

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const args = @import("../args.zig");
const editor = @import("../editor.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn run(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    style: output.Style,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    var parsed = try args.parseArgs(gpa, rest);
    defer parsed.deinit(gpa);
    const text = try args.joinParts(arena, parsed.parts.items);
    const via_editor = text.len == 0;
    if (via_editor) {
        // No text: -t TAG is meaningless (the buffer's `# tags:` line is
        // the only tag source), and so is a non-TTY (there is no editor
        // to open) — both stay usage errors.
        if (parsed.tags.items.len > 0 or !(File.isTty(File.stdout(), io) catch false)) {
            try output.printUsage(File.stderr(), io);
            return error.Usage;
        }
    }
    const now_ms = cli_journal.nowMs(io);
    const journal = try cli_journal.openReadJournal(arena, io, style, File.stderr(), environ_map, path, true);
    defer journal.close();
    // Verify before trust: never extend a failing journal.
    const pre = try journal.verify(arena);
    if (!pre.ok) {
        try output.reportIssue(File.stderr(), io, style, arena, pre.issue.?);
        return error.VerifyFailed;
    }
    if (via_editor) {
        try logViaEditor(arena, gpa, io, style, environ_map, path, &journal, now_ms);
        return;
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
    const seq_s = try style.accent(arena, try arena.print("{d}", .{seq}));
    try output.printLine(File.stdout(), io, try arena.print("{s}logged seq {s}", .{ try style.okMark(arena), seq_s }));
}

/// No text on a TTY: open the editor on an empty buffer and log what it
/// leaves. Canceling (a dim one-liner on stderr) is not an error.
fn logViaEditor(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    style: output.Style,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    journal: *const core.journal.Journal,
    now_ms: u64,
) errors.RunError!void {
    // `path` is the data directory: the editor's temp file lives beside
    // the journal (never /tmp — it is the user's entry).
    const seed = try editor.seedFor(gpa, &.{}, "");
    defer gpa.free(seed);
    const result = try editor.run(environ_map, io, gpa, path, seed);
    switch (result) {
        .cancelled => {
            try output.printLine(File.stderr(), io, try style.dim(arena, "cancelled"));
        },
        .content => |content| {
            const tz_offset_min = try journal.tzOffsetMinutesAtMs(now_ms);
            const seq = try journal.appendRecord(
                arena,
                core.records.RecordType.entry,
                0,
                content.text,
                content.tags,
                now_ms,
                tz_offset_min,
                false,
            );
            content.deinit(gpa);
            const seq_s = try style.accent(arena, try arena.print("{d}", .{seq}));
            try output.printLine(File.stdout(), io, try arena.print("{s}logged seq {s}", .{ try style.okMark(arena), seq_s }));
        },
    }
}
