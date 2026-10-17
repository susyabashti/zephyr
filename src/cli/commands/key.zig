//! zephyr key status: report where the journal's master key lives — the
//! store pinned by the journal's meta file (spec/encryption.md section 3.4).
//! Strictly read-only: it opens the journal without creating anything and
//! never reads key material — the store is addressed by the meta file
//! alone.

const std = @import("std");
const core = @import("zephyr_core");
const key = @import("zephyr_key");
const errors = @import("../errors.zig");
const output = @import("../output.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Environ = std.process.Environ;
const Allocator = std.mem.Allocator;

pub fn run(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    if (rest.len != 1 or !std.mem.eql(u8, rest[0], "status")) return error.Usage;

    var journal = core.journal.Journal.open(arena, io, environ_map, path, false) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try output.printLine(err_file, io, try arena.print(
                "{s}journal not found: {s}",
                .{ try style.errMark(arena), path },
            ));
            return error.JournalNotFound;
        },
        else => return err,
    };
    const meta = try journal.loadMeta(arena);
    const line = if (meta) |m| try statusLine(style, arena, path, &m) else try style.dim(arena, "no encryption key yet (the journal has no meta file)");
    return output.printLine(out, io, line);
}

fn statusLine(style: output.Style, allocator: Allocator, path: []const u8, meta: *const core.vault.Meta) Allocator.Error![]const u8 {
    return switch (meta.store) {
        .keychain => allocator.print("{s}key ok ({s}) · {s}", .{
            try style.okMark(allocator), key.resolve.storeDescription(meta), meta.key_id,
        }),
        .keyfile => allocator.print("{s}key ok (0600 key file) · {s}/{s}", .{
            try style.okMark(allocator), path, meta.key_id,
        }),
    };
}

// ------------------------------------------------------------- tests

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

fn writeMeta(io: Io, gpa: Allocator, dir: []const u8, store: core.vault.Store, key_id: []const u8) !void {
    const bytes = try core.vault.encodeMeta(gpa, store, key_id);
    defer gpa.free(bytes);
    const meta_file = try gpa.print("{s}/zephyr.meta", .{dir});
    defer gpa.free(meta_file);
    const f = try Dir.createFileAbsolute(io, meta_file, .{});
    defer File.close(f, io);
    try File.writeStreamingAll(f, io, bytes);
}

/// Runs the command with stdout pointed at a scratch file and returns its
/// contents (gpa-allocated). The arena absorbs every allocation the journal
/// retains for its lifetime (Journal.open, loadMeta), so only the returned
/// slice needs freeing.
fn runToBuffer(io: Io, gpa: Allocator, dir: []const u8, rest: []const []const u8) ![]u8 {
    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();
    var map = Environ.Map.init(gpa);
    defer map.deinit();
    const out_path = try gpa.print("{s}/out.txt", .{dir});
    defer gpa.free(out_path);
    {
        const out = try Dir.createFileAbsolute(io, out_path, .{});
        defer File.close(out, io);
        try run(arena, io, output.Style.off, File.stderr(), out, &map, dir, rest);
    }
    var buf: [4096]u8 = undefined;
    const rendered = try Dir.readFile(Dir.cwd(), io, out_path, &buf);
    return try gpa.dupe(u8, rendered);
}

test "key status: the keychain store pinned in the meta" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "key-status-kc");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }
    try writeMeta(io, gpa, dir, .keychain, core.vault.KeychainMasterAccount);

    const rendered = try runToBuffer(io, gpa, dir, &.{"status"});
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("✓ key ok (macOS Keychain) · master-v1\n", rendered);
}

test "key status: the key file store pinned in the meta" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "key-status-kf");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }
    try writeMeta(io, gpa, dir, .keyfile, core.vault.KeyFileName);

    const rendered = try runToBuffer(io, gpa, dir, &.{"status"});
    defer gpa.free(rendered);
    const expected = try gpa.print("✓ key ok (0600 key file) · {s}/zephyr.key\n", .{dir});
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, rendered);
}

test "key status: no meta file yet" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "key-status-none");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }

    const rendered = try runToBuffer(io, gpa, dir, &.{"status"});
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("no encryption key yet (the journal has no meta file)\n", rendered);
}

test "key status: anything but `status` is a usage error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir = try tempDir(io, gpa, "key-status-usage");
    defer {
        gpa.free(dir);
        Dir.deleteTree(Dir.cwd(), io, dir) catch {};
    }

    var map = Environ.Map.init(gpa);
    defer map.deinit();
    const err = run(gpa, io, output.Style.off, File.stderr(), File.stderr(), &map, dir, &.{"rotate"}) catch |e| e;
    try std.testing.expect(err == error.Usage);
}
