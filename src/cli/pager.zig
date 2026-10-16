//! git-style pagination for long TTY output: when a render is taller than
//! the terminal, it is delivered to a pager ($PAGER, default `less -R`).
//! Piped (non-TTY) output never pages, and the pager can be turned off
//! with --no-pager, a non-empty $NO_PAGER, or an empty $PAGER. A pager
//! that cannot start, or fails, falls back to writing the content
//! directly — output is never lost.
//!
//! The content reaches the pager through a temporary file in the journal's
//! data directory (never /tmp: the text is the user's journal). A file,
//! not a pipe: the child's wait/kill cleanup closes the fd it tracks, so
//! the parent may not pre-close the pipe's write end (a second close is
//! EBADF, a debug-build panic), yet a pager such as `cat` needs EOF to
//! exit (a write end left open deadlocks). A file has a natural EOF and
//! its fd is closed exactly once — by the child's cleanup.

const std = @import("std");
const output = @import("output.zig");
const table = @import("table.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Environ = std.process.Environ;

/// The pager's failures: the temp-file I/O, the spawn, and the write of
/// the text into the temp file. The child's wait is not among them: by
/// the time we wait, the content is on disk for the pager to read.
const PageError = error{TmpPathTooLong} ||
    std.process.SpawnError ||
    File.OpenError ||
    File.Writer.Error ||
    Dir.DeleteFileError;

/// Deliver `text` to `out`: through a pager when the output is taller
/// than the terminal and the pager is not disabled, directly otherwise.
/// `data_dir` (the journal's directory) hosts the pager's temp file.
pub fn show(
    out: File,
    io: Io,
    environ_map: *const Environ.Map,
    data_dir: []const u8,
    no_pager: bool,
    text: []const u8,
) File.Writer.Error!void {
    if (shouldPage(out, io, environ_map, no_pager, text)) {
        // The pager could not start, or failed: deliver the content
        // directly (output is never lost).
        page(environ_map, io, data_dir, text) catch return output.printBlock(out, io, text);
        return;
    }
    return output.printBlock(out, io, text);
}

/// True when the pager is off: --no-pager, a non-empty $NO_PAGER (git's
/// env_bool semantics: an empty value does not disable), or an empty
/// $PAGER.
pub fn pagerDisabled(environ_map: *const Environ.Map, no_pager: bool) bool {
    if (no_pager) return true;
    if (environ_map.get("NO_PAGER")) |v| {
        if (v.len > 0) return true;
    }
    if (environ_map.get("PAGER")) |v| {
        return v.len == 0;
    }
    return false;
}

/// True when `text` should go through a pager: the pager is enabled,
/// `out` is a TTY, and the text is taller than the terminal.
pub fn shouldPage(
    out: File,
    io: Io,
    environ_map: *const Environ.Map,
    no_pager: bool,
    text: []const u8,
) bool {
    if (pagerDisabled(environ_map, no_pager)) return false;
    if (!(File.isTty(out, io) catch false)) return false;
    return std.mem.count(u8, text, "\n") > table.terminalRows(out);
}

/// The pager's argv: $PAGER split on whitespace (at most 8 tokens; quoted
/// arguments are not supported), or `less -R` when unset or blank. The
/// token slices point into the environ map's values, which live for the
/// process; the token array is returned by value and is valid as long as
/// the caller keeps the result.
pub const Args = struct {
    tokens: [8][]const u8,
    count: usize,

    /// A view into this value's tokens: valid only while `self` lives.
    pub fn slices(self: *const Args) []const []const u8 {
        return self.tokens[0..self.count];
    }
};

pub fn pagerArgs(environ_map: *const Environ.Map) Args {
    if (environ_map.get("PAGER")) |spec| {
        var tokens: [8][]const u8 = undefined;
        var n: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= spec.len) : (i += 1) {
            const boundary = i == spec.len or std.ascii.isWhitespace(spec[i]);
            if (!boundary) continue;
            if (i > start and n < tokens.len) {
                tokens[n] = spec[start..i];
                n += 1;
            }
            start = i + 1;
        }
        if (n > 0) return Args{ .tokens = tokens, .count = n };
    }
    var default_tokens: [8][]const u8 = undefined;
    default_tokens[0] = "less";
    default_tokens[1] = "-R";
    return Args{ .tokens = default_tokens, .count = 2 };
}

/// Write `text` to a temp file in `data_dir` and hand it to the pager as
/// standard input, then wait for the pager to exit. The pager inherits
/// the terminal's stdout and stderr. Its exit status is not zephyr's
/// error: the content was delivered.
fn page(
    environ_map: *const Environ.Map,
    io: Io,
    data_dir: []const u8,
    text: []const u8,
) PageError!void {
    const argv = pagerArgs(environ_map);
    var buf: [2048]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &buf,
        "{s}/zephyr.pager-{d}.tmp",
        .{ data_dir, std.posix.system.getpid() },
    ) catch return error.TmpPathTooLong;
    // A previously crashed run may have left one; remove it so the file
    // created below is ours alone.
    Dir.deleteFileAbsolute(io, tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const tmp_file = try Dir.createFileAbsolute(io, tmp_path, .{});
    defer File.close(tmp_file, io);
    errdefer Dir.deleteFileAbsolute(io, tmp_path) catch {};
    try File.writeStreamingAll(tmp_file, io, text);

    const stdin_file = try Dir.openFileAbsolute(io, tmp_path, .{ .mode = .read_only });
    var child = try std.process.spawn(io, .{
        .exe = .detect,
        .argv = argv.slices(),
        .stdin = .{ .file = stdin_file },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    // Spawn dups our fd into the child; the parent's copy is ours to
    // close (the child's cleanup closes its own dup exactly once).
    File.close(stdin_file, io);
    // Idempotent: a no-op once wait has reaped the child.
    errdefer std.process.Child.kill(&child, io);
    _ = std.process.Child.wait(&child, io) catch std.process.Child.kill(&child, io);
    Dir.deleteFileAbsolute(io, tmp_path) catch {};
}

test "pager: disabled by the flag, a non-empty NO_PAGER, or an empty PAGER" {
    const gpa = std.testing.allocator;
    var map = Environ.Map.init(gpa);
    defer map.deinit();

    try std.testing.expect(!pagerDisabled(&map, false));
    try std.testing.expect(pagerDisabled(&map, true));

    try map.put("NO_PAGER", "");
    try std.testing.expect(!pagerDisabled(&map, false)); // empty = unset (git's env_bool)
    try map.put("NO_PAGER", "1");
    try std.testing.expect(pagerDisabled(&map, false));

    try map.put("NO_PAGER", "");
    try map.put("PAGER", "");
    try std.testing.expect(pagerDisabled(&map, false));
}

test "pager: argv from PAGER, whitespace-split, default less -R" {
    const gpa = std.testing.allocator;
    var map = Environ.Map.init(gpa);
    defer map.deinit();

    // The Args value must outlive the slices: a slice of a temporary's
    // field dangles as soon as the temporary dies. Compare the tokens'
    // bytes: std.meta.eql compares nested slices by pointer, so byte-
    // identical tokens from the map's values would fail.
    var a = pagerArgs(&map);
    try std.testing.expectEqual(@as(usize, 2), a.count);
    try std.testing.expectEqualStrings("less", a.tokens[0]);
    try std.testing.expectEqualStrings("-R", a.tokens[1]);

    try map.put("PAGER", "less -FRX");
    a = pagerArgs(&map);
    try std.testing.expectEqual(@as(usize, 2), a.count);
    try std.testing.expectEqualStrings("less", a.tokens[0]);
    try std.testing.expectEqualStrings("-FRX", a.tokens[1]);

    try map.put("PAGER", "   ");
    a = pagerArgs(&map);
    try std.testing.expectEqual(@as(usize, 2), a.count);
    try std.testing.expectEqualStrings("less", a.tokens[0]);
    try std.testing.expectEqualStrings("-R", a.tokens[1]);
}

test "pager: a non-TTY stream never pages" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const null_file = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_only });
    defer File.close(null_file, io);
    var map = Environ.Map.init(gpa);
    defer map.deinit();
    var lines = std.ArrayList(u8).empty;
    defer lines.deinit(gpa);
    for (0..100) |_| try lines.append(gpa, '\n'); // taller than any row count
    try std.testing.expect(!shouldPage(null_file, io, &map, false, lines.items));
}

test "pager: page() runs the pager and removes the temp file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    // A fresh empty directory under the cwd (`.gitignore` covers .tmp-*);
    // the *Absolute helpers require absolute paths.
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const base = try gpa.print("{s}/.tmp-pager-test", .{cwd_path});
    defer gpa.free(base);
    // Returns cleanly for a path that does not exist.
    Dir.deleteTree(Dir.cwd(), io, base) catch {};
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, base[cwd_path.len + 1 ..]);
    defer Dir.deleteTree(Dir.cwd(), io, base) catch {};

    var map = Environ.Map.init(gpa);
    defer map.deinit();
    // /usr/bin/true (present on macOS and Linux; /bin/true is gone from
    // recent macOS) ignores its stdin and exits: if page() returns, the
    // spawn and the wait completed.
    try map.put("PAGER", "/usr/bin/true");
    try page(&map, io, base, "hello pager");

    var buf: [2048]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &buf,
        "{s}/zephyr.pager-{d}.tmp",
        .{ base, std.posix.system.getpid() },
    ) catch return error.TmpPathTooLong;
    const err = Dir.openFileAbsolute(io, tmp_path, .{ .mode = .read_only }) catch |e| e;
    try std.testing.expect(err == error.FileNotFound);
}
