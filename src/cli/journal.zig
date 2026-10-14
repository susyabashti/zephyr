//! The shared journal access layer for the CLI commands: resolving the
//! journal path (`--journal`, $ZEPHYR_HOME), opening it for reads, the
//! verify-before-trust gate, the wall clock, and a sealed segment's footer
//! head (ots-stamp / ots-export).

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("errors.zig");
const output = @import("output.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn resolveJournalPath(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) core.journal.OpenError![]const u8 {
    const raw = if (explicit) |p| p else blk: {
        if (environ_map.get("ZEPHYR_HOME")) |home| break :blk home;
        if (environ_map.get("HOME")) |home| break :blk try allocator.print("{s}/.local/share/zephyr", .{home});
        return error.JournalNotFound;
    };
    if (std.Io.Dir.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    return try allocator.print("{s}/{s}", .{ cwd, raw });
}

pub fn openReadJournal(
    arena: Allocator,
    io: Io,
    err_file: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
) errors.RunError!core.journal.Journal {
    return core.journal.Journal.open(arena, io, environ_map, path, false) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try output.printLine(err_file, io, try arena.print("journal not found: {s}", .{path}));
            return error.JournalNotFound;
        },
        else => return err,
    };
}

pub fn verifyOrReport(arena: Allocator, io: Io, err_file: File, journal: *const core.journal.Journal) errors.RunError!core.journal.VerifyResult {
    const result = try journal.verify(arena);
    if (!result.ok) {
        try output.reportIssue(err_file, io, arena, result.issue.?);
        return error.VerifyFailed;
    }
    return result;
}

/// The sealed segment's 32-byte footer head (shared by ots-stamp and
/// ots-export). An unsealed segment is reported and becomes SegmentNotSealed.
pub fn sealedSegmentHead(
    arena: Allocator,
    io: Io,
    err_file: File,
    journal: *const core.journal.Journal,
    seg_name: []const u8,
) errors.RunError![32]u8 {
    const seg_bytes = try journal.readSegment(arena, seg_name);
    return core.segment.footerHead(seg_bytes) catch |err| switch (err) {
        error.NotSealed => {
            try output.printLine(err_file, io, try arena.print("segment {s} is not sealed; only sealed segments can be stamped", .{seg_name}));
            return error.SegmentNotSealed;
        },
        else => |e| return e,
    };
}

pub fn nowMs(io: Io) u64 {
    const ms = Io.Timestamp.now(io, .real).toMilliseconds();
    if (ms < 0) std.debug.panic("wall clock is before the Unix epoch", .{});
    return @intCast(ms);
}
