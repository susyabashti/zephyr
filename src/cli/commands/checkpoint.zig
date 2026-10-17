//! zephyr checkpoint [--key PATH] — sign the verified journal state into
//! an anchor artifact (anchors/checkpoint-<seq>.zpa). Key resolution:
//! --key PATH > $ZEPHYR_KEY > <journal>/zephyr-key (created 0600 on first
//! use).

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
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    var key_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--key")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            key_path = rest[i];
        } else {
            return error.Usage;
        }
    }
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path, false);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);

    // Key resolution: --key PATH > $ZEPHYR_KEY > <journal>/zephyr-key.
    const resolved_key = key_path orelse environ_map.get("ZEPHYR_KEY") orelse
        try arena.print("{s}/zephyr-key", .{path});
    const seed = try loadOrCreateKey(arena, io, resolved_key);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const now_ms = cli_journal.nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const seq = try journal.appendRecord(arena, .checkpoint, 0, "", &.{}, now_ms, offset, false);

    // Anchor only a verified state: re-verify after the append and bind the
    // resulting (head, count) to the key.
    const result = try journal.verify(arena);
    if (!result.ok) {
        try output.reportIssue(err_file, io, style, arena, result.issue.?);
        return error.VerifyFailed;
    }
    const bytes = try core.anchor.render(&kp, result.head, result.record_count, now_ms, seq);
    try journal.writeAnchorFile(arena, seq, &bytes);
    const anchor_path = try arena.print("anchors/checkpoint-{d}.zpa", .{seq});
    try output.printLine(out, io, try arena.print(
        "{s}checkpoint seq {d} → {s}",
        .{ try style.okMark(arena), seq, try style.dim(arena, anchor_path) },
    ));
}

/// Reads the 32-byte signing seed from the key file, or on first use
/// generates it from the OS CSPRNG and stores it with 0600 permissions.
fn loadOrCreateKey(allocator: Allocator, io: Io, key_path: []const u8) errors.RunError![32]u8 {
    var seed: [32]u8 = undefined;
    const d = if (std.fs.path.dirname(key_path)) |parent|
        try Dir.openDirAbsolute(io, parent, .{})
    else
        Dir.cwd();
    defer Dir.close(d, io);
    const file_name = std.fs.path.basename(key_path);
    const existing = Dir.readFileAlloc(d, io, file_name, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        if (bytes.len != 32) return error.BadKeyFile;
        @memcpy(&seed, bytes);
        return seed;
    }
    try Io.randomSecure(io, &seed);
    const key_file = Dir.createFile(d, io, file_name, .{
        .permissions = File.Permissions.fromMode(0o600),
    }) catch |err| switch (err) {
        else => return err,
    };
    defer File.close(key_file, io);
    try File.writeStreamingAll(key_file, io, &seed);
    return seed;
}
