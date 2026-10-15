//! zephyr edit <seq> [-t TAG]... "text" — amend an entry. An amendment
//! carries the entry's tags unless the user gives new ones, so a plain text
//! edit never silently drops tags.

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
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    if (rest.len == 0) return error.Usage;
    const target = std.fmt.parseInt(u64, rest[0], 10) catch return error.Usage;
    var parsed = try args.parseArgs(arena, rest[1..]);
    defer parsed.deinit(arena);
    const text = try args.joinParts(arena, parsed.parts.items);
    if (text.len == 0) {
        try output.printUsage(File.stderr(), io);
        return error.Usage;
    }
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    const recs = try journal.collectRecords(arena);
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
