//! zephyr edit <seq> [-t TAG]... "text" — amend an entry. An amendment
//! carries the entry's tags unless the user gives new ones, so a plain text
//! edit never silently drops tags. With only a seq on a TTY, the editor is
//! opened seeded with the entry's current text and tags; saving amends.

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
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    if (rest.len == 0) return error.Usage;
    const target = std.fmt.parseInt(u64, rest[0], 10) catch return error.Usage;
    var parsed = try args.parseArgs(gpa, rest[1..]);
    defer parsed.deinit(gpa);
    const text = try args.joinParts(arena, parsed.parts.items);
    if (text.len == 0) {
        // No text: only a bare seq (no -t — the buffer's `# tags:` line is
        // the only tag source) on a TTY opens the editor; anything else
        // is a usage error.
        if (rest.len != 1 or !(File.isTty(File.stdout(), io) catch false)) {
            try output.printUsage(File.stderr(), io);
            return error.Usage;
        }
    }
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path, false);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    const recs = try journal.collectPlaintext(arena);
    defer recs.deinit();
    const target_header = core.journal.Journal.resolveEditTarget(recs.headers, target) catch |err| {
        try output.reportTargetError(arena, io, style, err_file, target, err);
        return switch (err) {
            error.TargetNotFound => error.TargetNotFound,
            error.TargetNotEntry => error.TargetNotEntry,
        };
    };
    const tags = if (parsed.tags.items.len == 0)
        try effectiveTagsOf(arena, recs, target)
    else
        parsed.tags.items;
    if (text.len == 0) {
        try amendViaEditor(arena, gpa, io, style, out, environ_map, path, &journal, recs, target, tags, target_header);
        return;
    }
    const now_ms = cli_journal.nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const seq = try journal.appendRecord(
        arena,
        core.records.RecordType.amendment,
        target,
        text,
        tags,
        now_ms,
        offset,
        target_header.isPrivate(),
    );
    try printAmended(arena, io, style, out, target, seq);
}

/// Only a seq on a TTY: open the editor seeded with the entry's current
/// text and tags; saving amends with the buffer as the source of truth
/// (WYSIWYG — deleting the `# tags:` line clears the tags). Canceling (a
/// dim one-liner on stderr) is not an error.
fn amendViaEditor(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    style: output.Style,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    journal: *const core.journal.Journal,
    recs: core.journal.Journal.RecordSet,
    target: u64,
    tags: []const []const u8,
    target_header: *const core.records.Header,
) errors.RunError!void {
    const current_text = try currentTextOf(arena, recs, target);
    const seed = try editor.seedFor(gpa, tags, current_text);
    defer gpa.free(seed);
    const result = try editor.run(environ_map, io, gpa, path, seed);
    switch (result) {
        .cancelled => |reason| {
            const msg = if (reason == .unchanged) "unchanged" else "cancelled";
            try output.printLine(File.stderr(), io, try style.dim(arena, msg));
        },
        .content => |content| {
            const now_ms = cli_journal.nowMs(io);
            const offset = try journal.tzOffsetMinutesAtMs(now_ms);
            const seq = try journal.appendRecord(
                arena,
                core.records.RecordType.amendment,
                target,
                content.text,
                content.tags,
                now_ms,
                offset,
                target_header.isPrivate(),
            );
            content.deinit(gpa);
            try printAmended(arena, io, style, out, target, seq);
        },
    }
}

fn printAmended(
    arena: Allocator,
    io: Io,
    style: output.Style,
    out: File,
    target: u64,
    seq: u64,
) errors.RunError!void {
    const mark = try style.okMark(arena);
    const target_s = try style.accent(arena, try arena.print("{d}", .{target}));
    const seq_s = try style.accent(arena, try arena.print("{d}", .{seq}));
    try output.printLine(out, io, try arena.print("{s}amended seq {s} → {s}", .{ mark, target_s, seq_s }));
}

/// The tags the view currently shows for entry `seq`: the latest amendment's
/// tags, or the entry's own. Arena-allocated; borrows the payload bytes.
fn effectiveTagsOf(
    arena: Allocator,
    recs: core.journal.Journal.RecordSet,
    target: u64,
) (Allocator.Error || core.records.DecodePayloadError)![]const []const u8 {
    var result: ?[]const []const u8 = null;
    for (recs.headers, recs.payloads) |h, payload| {
        const interesting = (h.record_type == .entry and h.seq == target) or
            (h.record_type == .amendment and h.target_seq == target);
        if (!interesting) continue;
        const decoded = try core.records.decodePayload(arena, payload);
        result = decoded.tags;
    }
    return result orelse unreachable; // resolveEditTarget guarantees the entry exists
}

/// The text the view currently shows for entry `seq`: the latest
/// amendment's text, or the entry's own. Borrows the payload bytes.
fn currentTextOf(
    arena: Allocator,
    recs: core.journal.Journal.RecordSet,
    target: u64,
) (Allocator.Error || core.records.DecodePayloadError)![]const u8 {
    var result: ?[]const u8 = null;
    for (recs.headers, recs.payloads) |h, payload| {
        const interesting = (h.record_type == .entry and h.seq == target) or
            (h.record_type == .amendment and h.target_seq == target);
        if (!interesting) continue;
        const decoded = try core.records.decodePayload(arena, payload);
        result = decoded.text;
    }
    return result orelse unreachable; // resolveEditTarget guarantees the entry exists
}
