//! zephyr ots-stamp <segment> --proof <path> — attach a standard
//! OpenTimestamps proof of a sealed segment's footer head
//! (anchors/ots-<YYYY-MM>.ots).

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const ReadProofError = Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError ||
    std.process.CurrentPathError || error{TargetNotFound};

/// Reads the proof file at `path` (relative paths resolve against the
/// current directory). A missing file prints a message and becomes
/// TargetNotFound.
fn readProofFile(allocator: Allocator, io: Io, style: output.Style, err_file: File, path: []const u8) ReadProofError![]u8 {
    const abs = if (std.Io.Dir.path.isAbsolute(path))
        path
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        break :blk try allocator.print("{s}/{s}", .{ cwd, path });
    };
    const d = if (std.fs.path.dirname(abs)) |parent|
        try Dir.openDirAbsolute(io, parent, .{})
    else
        Dir.cwd();
    defer Dir.close(d, io);
    return Dir.readFileAlloc(d, io, std.fs.path.basename(abs), allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            output.printLine(err_file, io, try allocator.print("{s}no such file: {s}", .{ try style.errMark(allocator), path })) catch return error.InputOutput;
            return error.TargetNotFound;
        },
        else => return err,
    };
}

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
    var segment_name: ?[]const u8 = null;
    var proof_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--proof")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            if (proof_path != null) return error.Usage;
            proof_path = rest[i];
        } else if (segment_name != null or std.mem.startsWith(u8, arg, "-")) {
            return error.Usage;
        } else {
            segment_name = arg;
        }
    }
    const seg_name = segment_name orelse return error.Usage;
    const proof_file = proof_path orelse return error.Usage;
    if (!core.journal.isSegmentName(seg_name)) {
        try output.printLine(err_file, io, try arena.print("{s}no such segment: {s}", .{ try style.errMark(arena), seg_name }));
        return error.TargetNotFound;
    }

    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);

    const head = try cli_journal.sealedSegmentHead(arena, io, style, err_file, &journal, seg_name);
    var expected: [32]u8 = undefined;
    core.records.Sha256.hash(&head, &expected, .{});

    const proof = try readProofFile(arena, io, style, err_file, proof_file);
    const verification = core.ots.verify(arena, proof, &expected) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try output.printLine(err_file, io, try arena.print(
                "{s}proof verification failed: {s}",
                .{ try style.errMark(arena), output.otsFailureReason(e) },
            ));
            return error.BadOtsProof;
        },
    };

    const month = seg_name[0..7];
    try journal.writeOtsAnchorFile(arena, month, proof);
    const anchor_path = try arena.print("anchors/ots-{s}.ots", .{month});
    try output.printLine(out, io, try arena.print(
        "{s}ots · {s} · {s}",
        .{
            try style.okMark(arena),
            try style.dim(arena, anchor_path),
            try output.attestationSummary(arena, verification.attestations),
        },
    ));
}
