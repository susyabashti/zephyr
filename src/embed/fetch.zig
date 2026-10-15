//! Model fetcher (distribution): downloads the pinned embedding model
//! (model.zig) and installs it at a given path only after verification.
//! Std-only — no engine code — so it works in `--no-embed` builds too,
//! where it can pre-fetch the model for a later full build.
//!
//! Contract: the destination file appears only after verification. Bytes
//! are streamed to `<path>.tmp`; the completed file is checked against
//! the pinned size and sha256; only then is it renamed into place
//! (atomic within one filesystem). Any failure removes the temporary
//! file and leaves the destination untouched.
//!
//! Every public function requires an absolute path (std's *Absolute
//! entry points assert it); the CLI resolves relative paths first.

const std = @import("std");
const model = @import("model.zig");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;

const Chunk: usize = 1 << 20; // 1 MiB streaming chunk (the engine's)

pub const FetchError = error{
    /// The server answered with a status other than 200 OK.
    BadResponse,
    /// The downloaded bytes do not match the pinned size or sha256.
    HashMismatch,
    /// No existing ancestor directory of the destination could be found.
    ParentDirNotFound,
} || std.http.Client.FetchError ||
    File.OpenError || File.StatError || File.ReadPositionalError || File.Writer.Error ||
    Dir.OpenError || Dir.CreateDirPathError || Dir.RenameError || Dir.DeleteFileError;

/// The destination's state against the pin (full check; see `checkModel`).
pub const State = enum {
    /// No file at the path.
    absent,
    /// Present; size and sha256 match the pin.
    valid,
    /// Present; the size or the sha256 differs from the pin.
    invalid,
};

pub const Check = struct {
    present: bool,
    size: u64,
    /// The sha256 matches the pin (only when the size matches).
    hash_ok: bool,

    pub fn state(self: Check) State {
        if (!self.present) return .absent;
        return if (self.hash_ok) .valid else .invalid;
    }
};

/// Full check against the pin: size, then sha256 over the whole file —
/// a 313 MiB read when the size already matches. For `model fetch` and
/// `model status`, not for the hot path (see `preCheck`).
pub fn checkModel(
    io: Io,
    path: []const u8,
) (File.OpenError || File.StatError || File.ReadPositionalError)!Check {
    const file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return .{ .present = false, .size = 0, .hash_ok = false },
        else => return err,
    };
    defer File.close(file, io);
    const st = try file.stat(io);
    if (st.size != model.ModelBytes) {
        return .{ .present = true, .size = st.size, .hash_ok = false };
    }
    const hash = try hashFile(io, file);
    return .{
        .present = true,
        .size = st.size,
        .hash_ok = std.mem.eql(u8, &hash, &model.ModelSha256),
    };
}

/// Stat-only download decision (no hashing): the engine re-hashes the
/// model on every load, so the common case must not pay for a second
/// 313 MiB read.
pub const PreCheck = enum {
    /// No file; download.
    absent,
    /// Size differs from the pin; re-download (repair).
    wrong_size,
    /// Size matches; let the engine's hash gate decide.
    ok,
};

pub fn preCheck(io: Io, path: []const u8) (File.OpenError || File.StatError)!PreCheck {
    const file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    defer File.close(file, io);
    const st = try file.stat(io);
    return if (st.size == model.ModelBytes) .ok else .wrong_size;
}

/// Downloads the pinned model and installs it at `out_path` (absolute).
/// Streams to `<out_path>.tmp`, verifies against the pin, renames into
/// place. The start and completion lines go to `out_file` (plain text:
/// the fetcher is engine-side and stays free of CLI styling). Honors the
/// standard proxy environment variables (https_proxy and friends).
pub fn downloadAndInstall(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    out_file: File,
    out_path: []const u8,
) FetchError!void {
    const head = try gpa.print(
        "downloading {s} ({d} MiB) from huggingface.co",
        .{ model.ModelFile, @divFloor(model.ModelBytes, 1 << 20) },
    );
    defer gpa.free(head);
    try writeLine(out_file, io, head);

    try ensureParentDir(io, out_path);
    const tmp = try gpa.print("{s}.tmp", .{out_path});
    errdefer gpa.free(tmp);
    // A previously interrupted run may have left one; remove it so the
    // file opened below is ours alone.
    Dir.deleteFileAbsolute(io, tmp) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const tmp_file = try Dir.createFileAbsolute(io, tmp, .{});
    defer File.close(tmp_file, io);
    errdefer Dir.deleteFileAbsolute(io, tmp) catch {};

    var buf: [Chunk]u8 = undefined;
    var w = File.writerStreaming(tmp_file, io, &buf);
    // The client needs a thread-safe allocator; a private arena keeps its
    // allocations (including the proxy config's) together and frees them
    // with it.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var client = std.http.Client{ .allocator = arena.allocator(), .io = io };
    defer client.deinit();
    try client.initDefaultProxies(arena.allocator(), environ_map);
    const res = try client.fetch(.{
        .location = .{ .url = model.ModelDownloadUrl },
        .response_writer = &w.interface,
    });
    if (res.status != .ok) return error.BadResponse;
    // The writer buffers; nothing is on disk until it is flushed.
    try File.Writer.flush(&w);
    try installVerified(io, tmp, out_path);
    gpa.free(tmp); // the errdefer covers only the failure path
    const done = try gpa.print("✓ model ok (sha256 verified) · {s}", .{out_path});
    defer gpa.free(done);
    try writeLine(out_file, io, done);
}

/// Verifies the completed download at `tmp_path` against the pin and
/// renames it to `out_path` (both absolute, same filesystem). On
/// mismatch the temporary file is left in place; the caller removes it.
pub fn installVerified(io: Io, tmp_path: []const u8, out_path: []const u8) FetchError!void {
    const file = try Dir.openFileAbsolute(io, tmp_path, .{ .mode = .read_only });
    defer File.close(file, io);
    const st = try file.stat(io);
    if (st.size != model.ModelBytes) return error.HashMismatch;
    const hash = try hashFile(io, file);
    if (!std.mem.eql(u8, &hash, &model.ModelSha256)) return error.HashMismatch;
    try Dir.renameAbsolute(tmp_path, out_path, io);
}

/// Creates the destination's missing ancestor directories: walks up from
/// the parent to the nearest existing ancestor, then creates the missing
/// suffix in one call. `path` is an absolute file path.
fn ensureParentDir(io: Io, path: []const u8) FetchError!void {
    const parent = std.fs.path.dirname(path) orelse return;
    var candidate = parent;
    while (true) {
        const dir = Dir.openDirAbsolute(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                const up = std.fs.path.dirname(candidate) orelse return error.ParentDirNotFound;
                if (std.mem.eql(u8, up, candidate)) return error.ParentDirNotFound;
                candidate = up;
                continue;
            },
            else => return err,
        };
        defer Dir.close(dir, io);
        if (std.mem.eql(u8, candidate, parent)) return; // already there
        // `candidate` is a strict prefix of `parent` (only whole path
        // components were stripped); this is the missing suffix.
        const suffix = parent[candidate.len + 1 ..];
        try dir.createDirPath(io, suffix);
        return;
    }
}

/// sha256 of the whole file in 1 MiB chunks (the pinned model is 313
/// MiB; it is streamed, never slurped). The engine holds its own copy:
/// it only compiles in embed builds, and this module must stay
/// self-contained for the `--no-embed` ones.
fn hashFile(io: Io, file: File) File.ReadPositionalError![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [Chunk]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
    }
    return hasher.finalResult();
}

/// Unbuffered line (the same primitive the CLI's output.zig uses).
fn writeLine(file: File, io: Io, text: []const u8) File.Writer.Error!void {
    try File.writeStreamingAll(file, io, text);
    try File.writeStreamingAll(file, io, "\n");
}

// ------------------------------------------------------------------ tests
//
// The full download path needs the network and the 313 MiB pin, so the
// suite covers everything else: the stat checks, the verify+install
// gate, the chunked hashing, and directory creation. The pin itself is
// exercised end-to-end by the CI semantic gate (real model, real
// engine).

const testing = std.testing;

test "checkModel: absent" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = try tempDir(allocator, io, "absent");
    defer cleanupDir(io, dir);

    const path = try allocator.print("{s}/models/{s}", .{ dir, model.ModelFile });
    const check = try checkModel(io, path);
    try testing.expect(!check.present);
    try testing.expectEqual(@as(u64, 0), check.size);
    try testing.expect(check.state() == .absent);
}

test "checkModel: wrong size is invalid" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = try tempDir(allocator, io, "size");
    defer cleanupDir(io, dir);

    const path = try allocator.print("{s}/models/{s}", .{ dir, model.ModelFile });
    try ensureParentDir(io, path);
    try writeFile(io, path, "not the model");
    const check = try checkModel(io, path);
    try testing.expect(check.present);
    try testing.expectEqual(@as(u64, 13), check.size);
    try testing.expect(!check.hash_ok);
    try testing.expect(check.state() == .invalid);
}

test "preCheck: absent and wrong_size" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = try tempDir(allocator, io, "precheck");
    defer cleanupDir(io, dir);

    const path = try allocator.print("{s}/models/{s}", .{ dir, model.ModelFile });
    try testing.expect(try preCheck(io, path) == .absent);
    try ensureParentDir(io, path);
    try writeFile(io, path, "small");
    try testing.expect(try preCheck(io, path) == .wrong_size);
}

test "installVerified: wrong size is refused, destination untouched" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = try tempDir(allocator, io, "install");
    defer cleanupDir(io, dir);

    const tmp = try allocator.print("{s}/model.tmp", .{dir});
    const out = try allocator.print("{s}/models/{s}", .{ dir, model.ModelFile });
    try writeFile(io, tmp, "not the model");

    try testing.expectError(error.HashMismatch, installVerified(io, tmp, out));
    // The destination was never created, and the tmp survives for the
    // caller's error path to remove.
    try testing.expect(try preCheck(io, out) == .absent);
    try testing.expect(try preCheck(io, tmp) == .wrong_size);
}

test "hashFile: chunked read agrees with the one-shot digest" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = try tempDir(allocator, io, "hash");
    defer cleanupDir(io, dir);

    // 2.5 MiB of deterministic data: crosses several 1 MiB chunk
    // boundaries (the last one partially).
    const data = try allocator.alloc(u8, (2 << 20) + (1 << 20) / 2);
    for (data, 0..) |*b, i| b.* = @truncate(i);
    const path = try allocator.print("{s}/blob", .{dir});
    try writeFile(io, path, data);

    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer File.close(file, io);
    const chunked = try hashFile(io, file);
    var oneshot = std.crypto.hash.sha2.Sha256.init(.{});
    oneshot.update(data);
    try testing.expect(std.mem.eql(u8, &chunked, &oneshot.finalResult()));
}

test "ensureParentDir: creates nested directories, no-ops when present" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = try tempDir(allocator, io, "parent");
    defer cleanupDir(io, dir);

    const file = try allocator.print("{s}/a/b/c/{s}", .{ dir, model.ModelFile });

    try ensureParentDir(io, file);
    // The parent exists now; the file itself was not created.
    try testing.expect(try preCheck(io, file) == .absent);
    const d = try Dir.openDirAbsolute(io, try allocator.print("{s}/a/b/c", .{dir}), .{});
    defer Dir.close(d, io);

    // Running again must not fail (the suffix now exists).
    try ensureParentDir(io, file);
}

/// A fresh empty directory at `<cwd>/.tmp-fetch-<tag>` (`.gitignore`
/// covers `.tmp-*`). The returned path is allocated with the given
/// allocator; the caller removes the directory itself.
fn tempDir(
    allocator: Allocator,
    io: Io,
    tag: []const u8,
) (Allocator.Error || std.process.CurrentPathError || Dir.DeleteTreeError || Dir.OpenError || Dir.CreateDirPathError)![]const u8 {
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const base = try allocator.print("{s}/.tmp-fetch-{s}", .{ cwd_path, tag });
    const cwd = Dir.cwd();
    // deleteTree returns cleanly for a path that does not exist.
    try Dir.deleteTree(cwd, io, base);
    var dir = try Dir.openDirAbsolute(io, cwd_path, .{});
    defer Dir.close(dir, io);
    try dir.createDirPath(io, base[cwd_path.len + 1 ..]);
    return base;
}

fn cleanupDir(io: Io, path: []const u8) void {
    Dir.deleteTree(Dir.cwd(), io, path) catch {};
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) (File.OpenError || File.Writer.Error)!void {
    const f = try Dir.createFileAbsolute(io, path, .{});
    defer File.close(f, io);
    try File.writeStreamingAll(f, io, bytes);
}
