//! zephyr redact <seq> [--yes] — remove an entry's content from the file.
//! The record header and hash chain are kept, so the redaction itself is
//! visible. Prompts once (y/Y to proceed) unless --yes.

const std = @import("std");
const errors = @import("../errors.zig");
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
    if (rest.len < 1 or rest.len > 2) return error.Usage;
    const target = std.fmt.parseInt(u64, rest[0], 10) catch return error.Usage;
    var assume_yes = false;
    if (rest.len == 2) {
        if (!std.mem.eql(u8, rest[1], "--yes")) return error.Usage;
        assume_yes = true;
    }
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path, false);
    defer journal.close();
    _ = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    if (!assume_yes) {
        const proceed = try confirmRedact(arena, io, out, target);
        if (!proceed) {
            try output.printLine(out, io, "aborted");
            return;
        }
    }
    const now_ms = cli_journal.nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    // The redaction record's own seq is internal; the entry's seq is what
    // the user names, so the result is discarded.
    _ = try journal.redact(arena, target, now_ms, offset);
    const target_s = try style.accent(arena, try arena.print("{d}", .{target}));
    try output.printLine(out, io, try arena.print("{s}redacted seq {s}", .{ try style.okMark(arena), target_s }));
}

/// Prints the warning prompt and reads one line from stdin. Anything other
/// than y/Y aborts the redaction.
fn confirmRedact(arena: Allocator, io: Io, out: File, target: u64) errors.RunError!bool {
    const prompt_fmt =
        \\redact seq {d}? the entry's text and tags are removed from the file; the
        \\record header and hash chain are kept, so the redaction itself is visible.
        \\\Proceed? [y/N]
    ;
    const prompt = try arena.print(prompt_fmt, .{target});
    try File.writeStreamingAll(out, io, prompt);
    const stdin = File.stdin();
    var stream_buf: [4096]u8 = undefined;
    var line_buf: [16]u8 = undefined;
    var reader = File.reader(stdin, io, &stream_buf);
    const n = try std.Io.Reader.readSliceShort(&reader.interface, &line_buf);
    if (n == 0) return false;
    var end = n;
    if (line_buf[end - 1] == '\n') end -= 1;
    if (end > 0 and line_buf[end - 1] == '\r') end -= 1;
    return std.mem.eql(u8, line_buf[0..end], "y") or std.mem.eql(u8, line_buf[0..end], "Y");
}
