//! zephyr ots-export <segment> [--out <path>] — write the segment's
//! 32-byte footer head for external OpenTimestamps tooling (default:
//! <cwd>/<segment>.head); anchor the written file to get an .ots proof.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
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
    var segment_name: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            if (out_path != null) return error.Usage;
            out_path = rest[i];
        } else if (segment_name != null or std.mem.startsWith(u8, arg, "-")) {
            return error.Usage;
        } else {
            segment_name = arg;
        }
    }
    const seg_name = segment_name orelse return error.Usage;
    if (!core.journal.isSegmentName(seg_name)) {
        try output.printLine(err_file, io, try arena.print("no such segment: {s}", .{seg_name}));
        return error.TargetNotFound;
    }

    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, err_file, &journal);

    const head = try cli_journal.sealedSegmentHead(arena, io, err_file, &journal, seg_name);

    const target = out_path orelse blk: {
        const cwd = try std.process.currentPathAlloc(io, arena);
        break :blk try arena.print("{s}/{s}.head", .{ cwd, seg_name });
    };
    const display = out_path orelse target;
    const d = if (std.fs.path.dirname(target)) |parent|
        try Dir.openDirAbsolute(io, parent, .{})
    else
        Dir.cwd();
    defer Dir.close(d, io);
    const f = Dir.createFile(d, io, std.fs.path.basename(target), .{}) catch |err| switch (err) {
        else => return err,
    };
    defer File.close(f, io);
    try File.writeStreamingAll(f, io, &head);
    try output.printLine(out, io, try arena.print(
        "ots-export: wrote {s} (head {s}); anchor this file to get an .ots proof",
        .{ display, try output.hexOf(arena, &head) },
    ));
}
