//! CLI: zephyr <text>  |  zephyr log [-t TAG]... <text>  |  zephyr verify
//!
//! Exit codes: 0 ok, 1 integrity or journal error, 2 usage error.

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub const Version: []const u8 = "0.1.0";

pub const RunError = error{
    Usage,
    VerifyFailed,
    JournalNotFound,
} || core.journal.OpenError || core.journal.Journal.AppendError ||
    core.journal.Journal.VerifyError || File.Writer.Error;

pub fn run(init: std.process.Init, args: []const []const u8) RunError!void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const out = File.stdout();
    const err_file = File.stderr();

    var journal_path: ?[]const u8 = null;
    var i: usize = 1;
    // Global options before the command.
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--journal")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            journal_path = args[i];
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try printLine(out, io, "zephyr " ++ Version ++ " (format v1)");
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
            try printUsage(err_file, io);
            return;
        } else {
            break;
        }
    }
    if (i >= args.len) {
        try printUsage(err_file, io);
        return error.Usage;
    }
    const command = args[i];

    // A bare word (not a known command) is a quick log; the word itself is the
    // first part of the text, so `rest` starts at `command`, not after it.
    if (isCommand(command)) {
        const rest = args[i + 1 ..];
        const path = try resolveJournalPath(arena, io, init.environ_map, journal_path);
        if (std.mem.eql(u8, command, "log")) {
            const seq = try runLog(arena, gpa, io, init.environ_map, path, rest);
            try printLine(out, io, try arena.print("logged seq {d}", .{seq}));
        } else {
            try runVerify(arena, io, err_file, out, init.environ_map, path);
        }
    } else {
        const path = try resolveJournalPath(arena, io, init.environ_map, journal_path);
        const seq = try runLog(arena, gpa, io, init.environ_map, path, args[i..]);
        try printLine(out, io, try arena.print("logged seq {d}", .{seq}));
    }
}

fn isCommand(s: []const u8) bool {
    return std.mem.eql(u8, s, "log") or std.mem.eql(u8, s, "verify");
}

fn runLog(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!u64 {
    var tags = std.ArrayList([]const u8).empty;
    defer tags.deinit(gpa);
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(gpa);
    var j: usize = 0;
    while (j < rest.len) : (j += 1) {
        const arg = rest[j];
        if (std.mem.eql(u8, arg, "-t")) {
            j += 1;
            if (j >= rest.len) return error.Usage;
            try tags.append(gpa, rest[j]);
        } else if (std.mem.startsWith(u8, arg, "-t") and arg.len > 2) {
            try tags.append(gpa, arg[2..]);
        } else {
            try parts.append(gpa, arg);
        }
    }
    if (parts.items.len == 0) {
        try printUsage(File.stderr(), io);
        return error.Usage;
    }
    // Join parts with a single space.
    var text_size: usize = 0;
    for (parts.items) |p| text_size += p.len + 1;
    const text = try arena.alloc(u8, text_size - 1);
    var w: usize = 0;
    for (parts.items, 0..) |p, k| {
        if (k > 0) {
            text[w] = ' ';
            w += 1;
        }
        @memcpy(text[w .. w + p.len], p);
        w += p.len;
    }

    const now_ms: u64 = @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
    const journal = try core.journal.Journal.open(arena, io, environ_map, path, true);
    defer journal.close();
    // Verify before trust: never extend a failing journal.
    const pre = try journal.verify(arena);
    if (!pre.ok) {
        try reportIssue(File.stderr(), io, arena, pre.issue.?);
        return error.VerifyFailed;
    }
    const tz_offset_min = try journal.tzOffsetMinutesAtMs(now_ms);
    return journal.appendRecord(
        arena,
        core.records.RecordType.entry,
        0,
        text,
        tags.items,
        now_ms,
        tz_offset_min,
        false,
    );
}

fn runVerify(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
) RunError!void {
    const journal = core.journal.Journal.open(arena, io, environ_map, path, false) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try printLine(err_file, io, try arena.print("journal not found: {s}", .{path}));
            return error.JournalNotFound;
        },
        else => return err,
    };
    defer journal.close();

    const result = try journal.verify(arena);
    if (result.ok) {
        const line = if (result.record_count == 0) "ok: journal is empty" else blk: {
            const head_hex = try hexOf(arena, &result.head);
            const redacted = if (result.redacted_count > 0)
                try arena.print(", {d} redacted", .{result.redacted_count})
            else
                "";
            break :blk try arena.print("ok: {d} record(s), head {s}{s}", .{ result.record_count, head_hex, redacted });
        };
        try printLine(out, io, line);
    } else {
        try reportIssue(err_file, io, arena, result.issue.?);
        return error.VerifyFailed;
    }
}

fn resolveJournalPath(
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

fn reportIssue(file: File, io: Io, allocator: Allocator, issue: core.journal.VerifyIssue) RunError!void {
    const line = try allocator.print("FAIL: {s} seq {d} {s}: {s}", .{ issue.file, issue.seq, issue.field, issue.detail });
    try printLine(file, io, line);
}

fn printLine(file: File, io: Io, text: []const u8) File.Writer.Error!void {
    try File.writeStreamingAll(file, io, text);
    try File.writeStreamingAll(file, io, "\n");
}

fn printUsage(file: File, io: Io) File.Writer.Error!void {
    const usage =
        \\zephyr — local-first, tamper-evident journal
        \\
        \\Usage:
        \\  zephyr "text"                  quick log
        \\  zephyr log [-t TAG]... "text"  log with optional tags
        \\  zephyr verify                  full integrity check
        \\
        \\Options:
        \\  --journal PATH    journal directory (default: $ZEPHYR_HOME or
        \\                    ~/.local/share/zephyr)
        \\  --version         print version
        \\  --help            this help
        \\
    ;
    return File.writeStreamingAll(file, io, usage);
}

fn hexOf(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, hash.len * 2);
    for (hash, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}
