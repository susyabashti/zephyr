//! Editor-based entry creation and amendment: `zephyr` (no args),
//! `zephyr log` (no text), and `zephyr edit <seq>` (no text) open the
//! user's editor on a temp file in the journal's data directory. The
//! editor is $VISUAL, then $EDITOR, then `vi`; whitespace-split like
//! $PAGER (quoted arguments are not supported).
//!
//! Buffer format: when the first line starts with `# tags:`, it is the
//! entry's tag list (comma-separated, trimmed, empty parts dropped) —
//! the single source of truth for tags; flags never pre-fill it.
//! Everything after the first line is the entry text. The record format
//! forbids newlines in text, so the remaining lines are joined into one
//! (trimmed, blank lines dropped, single spaces). Other `#` lines stay
//! text — hashtags survive. Without a tags line, the whole buffer is
//! text.
//!
//! Canceling (a dim one-liner, exit 0, nothing logged): the editor exits
//! non-zero, the joined text is empty, or (amend) the buffer parses to
//! the same tags and text as the seed. The temp file lives beside the
//! journal (never /tmp: it is the user's entry) and is removed on every
//! path.

const std = @import("std");
const args = @import("args.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Environ = std.process.Environ;
const Allocator = std.mem.Allocator;

/// The editor's failures: the temp-file I/O and the spawn. The editor's
/// exit status is not an error — it is a cancel.
const EditorError = error{TmpPathTooLong} ||
    std.process.SpawnError ||
    File.OpenError ||
    File.Writer.Error ||
    std.Io.Reader.ShortError ||
    Dir.DeleteFileError;

/// Why an editor run logged nothing.
pub const CancelReason = enum {
    /// The editor exited non-zero (or could not be waited on).
    editor_failed,
    /// The buffer's text (after joining) is empty.
    empty_text,
    /// The buffer parses to the same tags and text as the seed.
    unchanged,
};

/// A parsed editor buffer; every field is `allocator`-allocated. Free
/// with `deinit`.
pub const Parsed = struct {
    /// The tag slices and the slice itself are allocator-owned.
    tags: []const []const u8,
    /// The text joined to a single line.
    text: []const u8,

    pub fn deinit(self: *const Parsed, allocator: Allocator) void {
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
        allocator.free(self.text);
    }
};

/// The outcome of `run`. `content` is owned by the `gpa` passed to
/// `run`; free it with `Parsed.deinit`.
pub const Result = union(enum) {
    cancelled: CancelReason,
    content: Parsed,
};

/// The editor's argv: $VISUAL, then $EDITOR, then `vi` (a blank value
/// falls through to the next).
pub fn resolve(environ_map: *const Environ.Map) args.Args {
    const names = [_][]const u8{ "VISUAL", "EDITOR" };
    for (names) |name| {
        if (environ_map.get(name)) |spec| {
            const a = args.splitWhitespace(spec);
            if (a.count > 0) return a;
        }
    }
    var tokens: [8][]const u8 = undefined;
    tokens[0] = "vi";
    return args.Args{ .tokens = tokens, .count = 1 };
}

/// The buffer handed to the editor: the `# tags:` line (always present,
/// possibly without tags) followed by the entry's text.
/// Allocator-allocated.
pub fn seedFor(
    allocator: Allocator,
    tags: []const []const u8,
    text: []const u8,
) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# tags:");
    if (tags.len > 0) {
        try out.append(allocator, ' ');
        for (tags, 0..) |t, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, t);
        }
    }
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, text);
    return out.toOwnedSlice(allocator);
}

/// Parse an editor buffer: the tags from a leading `# tags:` line, and
/// the remaining lines joined into one (trimmed, blank lines dropped,
/// single spaces). All output is `allocator`-allocated.
pub fn parseBuffer(allocator: Allocator, buf: []const u8) Allocator.Error!Parsed {
    // Each tag string is duplicated into the allocator: the list's
    // storage holds the headers, and the tags outlive the buffer. On a
    // successful toOwnedSlice the list is empty, so this is a no-op.
    var tags_list = std.ArrayList([]const u8).empty;
    errdefer {
        for (tags_list.items) |t| allocator.free(t);
        tags_list.deinit(allocator);
    }
    var text_list = std.ArrayList(u8).empty;
    errdefer text_list.deinit(allocator);

    var rest: []const u8 = buf;
    if (std.mem.indexOfScalar(u8, buf, '\n')) |nl| {
        const first_line = buf[0..nl];
        if (std.mem.startsWith(u8, first_line, "# tags:")) {
            parseTagsInto(allocator, &tags_list, first_line["# tags:".len..]) catch |err| return err;
            rest = buf[nl + 1 ..];
        }
    } else if (std.mem.startsWith(u8, buf, "# tags:")) {
        parseTagsInto(allocator, &tags_list, buf["# tags:".len..]) catch |err| return err;
        rest = "";
    }

    // Join the remaining lines: trim each, drop blanks, single spaces.
    var joined_any = false;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        const boundary = i == rest.len or rest[i] == '\n';
        if (!boundary) continue;
        var lo = line_start;
        var hi = i;
        while (lo < hi and std.ascii.isWhitespace(rest[lo])) lo += 1;
        while (hi > lo and std.ascii.isWhitespace(rest[hi - 1])) hi -= 1;
        if (hi > lo) {
            if (joined_any) try text_list.append(allocator, ' ');
            try text_list.appendSlice(allocator, rest[lo..hi]);
            joined_any = true;
        }
        line_start = i + 1;
    }

    const tags = try tags_list.toOwnedSlice(allocator);
    errdefer allocator.free(tags);
    const text = try text_list.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    return Parsed{ .tags = tags, .text = text };
}

/// Split the text after `# tags:` on commas into trimmed, non-empty tags,
/// appending them to `out`.
fn parseTagsInto(
    allocator: Allocator,
    out: *std.ArrayList([]const u8),
    spec: []const u8,
) Allocator.Error!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= spec.len) : (i += 1) {
        const boundary = i == spec.len or spec[i] == ',';
        if (!boundary) continue;
        var lo = start;
        var hi = i;
        while (lo < hi and std.ascii.isWhitespace(spec[lo])) lo += 1;
        while (hi > lo and std.ascii.isWhitespace(spec[hi - 1])) hi -= 1;
        if (hi > lo) {
            const tag = try allocator.dupe(u8, spec[lo..hi]);
            errdefer allocator.free(tag);
            try out.append(allocator, tag);
        }
        start = i + 1;
    }
}

fn tagsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Open the editor on `seed` (a temp file in `data_dir`), wait for it to
/// exit, read the buffer back, and parse it. Canceling is a union tag,
/// not an error. The temp file is removed on every path. `content` is
/// `gpa`-allocated.
pub fn run(
    environ_map: *const Environ.Map,
    io: Io,
    gpa: Allocator,
    data_dir: []const u8,
    seed: []const u8,
) EditorError!Result {
    var buf: [2048]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &buf,
        "{s}/zephyr.editor-{d}.tmp",
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
    try File.writeStreamingAll(tmp_file, io, seed);

    var argv: [9][]const u8 = undefined;
    const editor = resolve(environ_map);
    for (editor.slices(), 0..) |tok, k| argv[k] = tok;
    argv[editor.count] = tmp_path;

    // The editor is a TTY program: all stdio is inherited, and the file
    // reaches it as an argv argument (no pipe, no stdin-file trick).
    var child = try std.process.spawn(io, .{
        .exe = .detect,
        .argv = argv[0 .. editor.count + 1],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    // Idempotent: a no-op once wait has reaped the child.
    errdefer std.process.Child.kill(&child, io);
    // The editor's exit status is not an error: a failure cancels.
    const succeeded: bool = blk: {
        const term = std.process.Child.wait(&child, io) catch {
            std.process.Child.kill(&child, io);
            break :blk false;
        };
        break :blk std.process.Child.Term.success(term);
    };
    if (!succeeded) {
        Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return .{ .cancelled = .editor_failed };
    }

    // The block's normal returns are not error returns, so the outer
    // errdefer would not fire; the delete below covers them.
    const result: Result = blk: {
        // Read the buffer back; the editor may have grown it. A fresh
        // read handle: the write end above sits at the seed's EOF.
        const read_file = try Dir.openFileAbsolute(io, tmp_path, .{ .mode = .read_only });
        defer File.close(read_file, io);
        var chunk: [4096]u8 = undefined;
        var reader = File.readerStreaming(read_file, io, &chunk);
        var buf_list = std.ArrayList(u8).empty;
        errdefer buf_list.deinit(gpa);
        while (true) {
            const n = try std.Io.Reader.readSliceShort(&reader.interface, &chunk);
            if (n == 0) break;
            try buf_list.appendSlice(gpa, chunk[0..n]);
        }
        const buffer = try buf_list.toOwnedSlice(gpa);
        errdefer gpa.free(buffer);

        const seed_parsed = try parseBuffer(gpa, seed);
        defer seed_parsed.deinit(gpa);
        const parsed = try parseBuffer(gpa, buffer);
        gpa.free(buffer);

        // Unchanged before empty: an untouched buffer is a no-op,
        // whatever its content.
        if (tagsEqual(parsed.tags, seed_parsed.tags) and std.mem.eql(u8, parsed.text, seed_parsed.text)) {
            parsed.deinit(gpa);
            break :blk .{ .cancelled = .unchanged };
        }
        if (parsed.text.len == 0) {
            parsed.deinit(gpa);
            break :blk .{ .cancelled = .empty_text };
        }
        break :blk .{ .content = parsed };
    };
    Dir.deleteFileAbsolute(io, tmp_path) catch {};
    return result;
}

test "editor: resolve VISUAL > EDITOR > vi, whitespace split, blank falls through" {
    const gpa = std.testing.allocator;
    var map = Environ.Map.init(gpa);
    defer map.deinit();

    var a = resolve(&map);
    try std.testing.expectEqual(@as(usize, 1), a.count);
    try std.testing.expectEqualStrings("vi", a.tokens[0]);

    try map.put("EDITOR", "nano");
    a = resolve(&map);
    try std.testing.expectEqual(@as(usize, 1), a.count);
    try std.testing.expectEqualStrings("nano", a.tokens[0]);

    // VISUAL wins over EDITOR; its value is whitespace-split.
    try map.put("VISUAL", "  code -w  ");
    a = resolve(&map);
    try std.testing.expectEqual(@as(usize, 2), a.count);
    try std.testing.expectEqualStrings("code", a.tokens[0]);
    try std.testing.expectEqualStrings("-w", a.tokens[1]);

    // A blank VISUAL falls through to EDITOR.
    try map.put("VISUAL", "   ");
    a = resolve(&map);
    try std.testing.expectEqual(@as(usize, 1), a.count);
    try std.testing.expectEqualStrings("nano", a.tokens[0]);
}

/// Parse `buf` and check the tags and the text; the result is freed
/// before returning. (A test body must not reassign one `Parsed` across
/// several `defer p.deinit` calls: defers bind the variable, so every
/// defer would free the last value.)
fn checkParse(
    allocator: Allocator,
    buf: []const u8,
    expected_tags: []const []const u8,
    expected_text: []const u8,
) (Allocator.Error || error{TestExpectedEqual})!void {
    const p = try parseBuffer(allocator, buf);
    defer p.deinit(allocator);
    try std.testing.expectEqual(expected_tags.len, p.tags.len);
    for (expected_tags, p.tags) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings(expected_text, p.text);
}

test "editor: parseBuffer the tags line and the joined text" {
    const gpa = std.testing.allocator;

    try checkParse(gpa, "# tags: a, b\nhello world\n", &.{ "a", "b" }, "hello world");

    // An empty tags line is legal; a `#` line after the first is text.
    try checkParse(gpa, "# tags:\n# a hashtag\nline two", &.{}, "# a hashtag line two");

    // No tags line: the whole buffer is text.
    try checkParse(gpa, "hello # not a tag line", &.{}, "hello # not a tag line");

    // Double commas, stray whitespace, and a trailing blank line.
    try checkParse(gpa, "# tags: a,, b \n  one  \n\n  two\n", &.{ "a", "b" }, "one two");

    // The degenerate buffers.
    try checkParse(gpa, "", &.{}, "");
    try checkParse(gpa, "# tags: a", &.{"a"}, "");
}

test "editor: seedFor the exact bytes" {
    const gpa = std.testing.allocator;

    // Blocks, not a reassignment: a `defer` on one `var` would free the
    // same final value twice.
    {
        const s = try seedFor(gpa, &[_][]const u8{ "a", "b" }, "hello");
        defer gpa.free(s);
        try std.testing.expectEqualStrings("# tags: a, b\nhello", s);
    }
    {
        const s = try seedFor(gpa, &[_][]const u8{}, "");
        defer gpa.free(s);
        try std.testing.expectEqualStrings("# tags:\n", s);
    }
}

/// A fresh empty directory under the cwd (`.gitignore` covers .tmp-*);
/// the *Absolute helpers require absolute paths.
fn tempDir(io: Io, gpa: Allocator, tag: []const u8) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const base = try gpa.print("{s}/.tmp-{s}", .{ cwd_path, tag });
    Dir.deleteTree(Dir.cwd(), io, base) catch {};
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, base[cwd_path.len + 1 ..]);
    errdefer Dir.deleteTree(Dir.cwd(), io, base) catch {};
    return base;
}

/// Write `content` to `<dir>/seed.txt` and return the absolute path
/// (gpa-allocated; the caller frees it).
fn writeSeedFile(io: Io, gpa: Allocator, dir: []const u8, content: []const u8) ![]u8 {
    const seed_file = try gpa.print("{s}/seed.txt", .{dir});
    errdefer gpa.free(seed_file);
    const f = try Dir.createFileAbsolute(io, seed_file, .{});
    defer File.close(f, io);
    try File.writeStreamingAll(f, io, content);
    return seed_file;
}

/// The temp file `run` creates is gone when it returns.
fn expectTmpRemoved(io: Io, data_dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &buf,
        "{s}/zephyr.editor-{d}.tmp",
        .{ data_dir, std.posix.system.getpid() },
    ) catch return error.TmpPathTooLong;
    const err = Dir.openFileAbsolute(io, tmp_path, .{ .mode = .read_only }) catch |e| e;
    try std.testing.expect(err == error.FileNotFound);
}

test "editor: a new entry returns the editor's tags and text" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "editor-run");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }
    // The editor "edit" overwrites the temp file with this buffer.
    const seed_file = try writeSeedFile(io, gpa, dir, "# tags: a\nedited text\n");
    defer gpa.free(seed_file);
    const editor_spec = try gpa.print("/bin/cp {s}", .{seed_file});
    defer gpa.free(editor_spec);

    var map = Environ.Map.init(gpa);
    defer map.deinit();
    try map.put("VISUAL", editor_spec);

    const result = try run(&map, io, gpa, dir, "# tags:\n");
    defer switch (result) {
        .cancelled => {},
        .content => |p| p.deinit(gpa),
    };
    switch (result) {
        .cancelled => unreachable,
        .content => |p| {
            try std.testing.expectEqual(@as(usize, 1), p.tags.len);
            try std.testing.expectEqualStrings("a", p.tags[0]);
            try std.testing.expectEqualStrings("edited text", p.text);
        },
    }
    try expectTmpRemoved(io, dir);
}

test "editor: a non-zero editor exit cancels" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "editor-fail");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }
    var map = Environ.Map.init(gpa);
    defer map.deinit();
    try map.put("VISUAL", "/usr/bin/false");

    const result = try run(&map, io, gpa, dir, "# tags:\n");
    defer switch (result) {
        .cancelled => {},
        .content => |p| p.deinit(gpa),
    };
    try std.testing.expectEqual(@as(CancelReason, .editor_failed), switch (result) {
        .cancelled => |r| r,
        .content => unreachable,
    });
    try expectTmpRemoved(io, dir);
}

test "editor: an unchanged buffer cancels" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "editor-unchanged");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }
    const seed_file = try writeSeedFile(io, gpa, dir, "# tags: a\nhello\n");
    defer gpa.free(seed_file);
    const editor_spec = try gpa.print("/bin/cp {s}", .{seed_file});
    defer gpa.free(editor_spec);

    var map = Environ.Map.init(gpa);
    defer map.deinit();
    try map.put("VISUAL", editor_spec);

    // The seed has no trailing newline (journal text never does); the
    // buffer does — parsing, not raw bytes, decides "unchanged".
    const result = try run(&map, io, gpa, dir, "# tags: a\nhello");
    defer switch (result) {
        .cancelled => {},
        .content => |p| p.deinit(gpa),
    };
    try std.testing.expectEqual(@as(CancelReason, .unchanged), switch (result) {
        .cancelled => |r| r,
        .content => unreachable,
    });
    try expectTmpRemoved(io, dir);
}

test "editor: an empty result cancels" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "editor-empty");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }
    const seed_file = try writeSeedFile(io, gpa, dir, "# tags:\n");
    defer gpa.free(seed_file);
    const editor_spec = try gpa.print("/bin/cp {s}", .{seed_file});
    defer gpa.free(editor_spec);

    var map = Environ.Map.init(gpa);
    defer map.deinit();
    try map.put("VISUAL", editor_spec);

    const result = try run(&map, io, gpa, dir, "unrelated seed text");
    defer switch (result) {
        .cancelled => {},
        .content => |p| p.deinit(gpa),
    };
    try std.testing.expectEqual(@as(CancelReason, .empty_text), switch (result) {
        .cancelled => |r| r,
        .content => unreachable,
    });
    try expectTmpRemoved(io, dir);
}

test "editor: a changed buffer returns the parsed content" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "editor-content");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }
    const seed_file = try writeSeedFile(io, gpa, dir, "# tags: work\n  line one  \n\n  line two\n");
    defer gpa.free(seed_file);
    const editor_spec = try gpa.print("/bin/cp {s}", .{seed_file});
    defer gpa.free(editor_spec);

    var map = Environ.Map.init(gpa);
    defer map.deinit();
    try map.put("VISUAL", editor_spec);

    const result = try run(&map, io, gpa, dir, "# tags: a\nhello");
    defer switch (result) {
        .cancelled => {},
        .content => |p| p.deinit(gpa),
    };
    switch (result) {
        .cancelled => unreachable,
        .content => |p| {
            try std.testing.expectEqual(@as(usize, 1), p.tags.len);
            try std.testing.expectEqualStrings("work", p.tags[0]);
            try std.testing.expectEqualStrings("line one line two", p.text);
        },
    }
    try expectTmpRemoved(io, dir);
}
