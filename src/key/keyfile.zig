//! Key file store (spec/encryption.md section 3.2): the 32-byte master key
//! as a 0600 file beside the journal. The fallback store on every platform
//! and the only one off macOS.

const std = @import("std");
const vault = @import("zephyr_core").vault;

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const posix = std.posix;

/// fchmod is not exposed by std.posix in 0.17; the POSIX declaration is
/// stable.
extern fn fchmod(fd: posix.fd_t, mode: posix.mode_t) i32;

pub const Error = error{
    /// The key file does not exist.
    KeyNotFound,
    /// The key file exists but is not exactly 32 bytes.
    BadKeyFile,
    /// `zephyr.key` already exists (or the mode could not be locked in).
    AlreadyExists,
    PermissionDenied,
} || File.OpenError || File.Reader.Error || File.Writer.Error || Io.RandomSecureError;

/// Writes a fresh random master key to `<journal>/zephyr.key` with mode
/// 0600 and returns the key bytes. Fails with `error.AlreadyExists` when
/// the file is already there — a store is only created when the journal
/// has no meta file, and the key file is never deleted by zephyr.
pub fn create(journal_dir: Dir, io: Io) Error![vault.KeyLen]u8 {
    var key: [vault.KeyLen]u8 = undefined;
    Io.randomSecure(io, &key) catch |err| return switch (err) {
        else => return err,
    };
    try storeFresh(journal_dir, io, &key);
    return key;
}

/// Writes `key` to a fresh exclusive file with mode 0600 locked in before
/// any key byte reaches the disk.
fn storeFresh(journal_dir: Dir, io: Io, key: *const [vault.KeyLen]u8) Error!void {
    const file = Dir.createFile(journal_dir, io, vault.KeyFileName, .{ .exclusive = true }) catch |err| switch (err) {
        error.FileBusy, error.PathAlreadyExists => return error.AlreadyExists,
        else => return err,
    };
    defer File.close(file, io);
    if (fchmod(file.handle, 0o600) != 0) return error.PermissionDenied;
    File.writeStreamingAll(file, io, key) catch |err| return switch (err) {
        else => return err,
    };
}

/// Reads the master key from `<journal>/zephyr.key`.
pub fn load(journal_dir: Dir, io: Io) Error![vault.KeyLen]u8 {
    var key: [vault.KeyLen]u8 = undefined;
    const n = Dir.readFile(journal_dir, io, vault.KeyFileName, &key) catch |err| switch (err) {
        error.FileNotFound => return error.KeyNotFound,
        else => return err,
    };
    if (n.len != vault.KeyLen) return error.BadKeyFile;
    return key;
}

/// A fresh empty directory under the cwd (`.gitignore` covers .tmp-*);
/// the *Absolute helpers require absolute paths.
fn tempDir(io: Io, gpa: std.mem.Allocator, tag: []const u8) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const base = try gpa.print("{s}/.tmp-keyfile-{s}", .{ cwd_path, tag });
    Dir.deleteTree(Dir.cwd(), io, base) catch {};
    try Dir.cwd().createDirPath(io, base[cwd_path.len + 1 ..]);
    return base;
}

test "keyfile create and load round trip" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir_path = try tempDir(io, gpa, "round-trip");
    defer {
        gpa.free(dir_path);
        Dir.deleteTree(Dir.cwd(), io, dir_path) catch {};
    }
    const dir = Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch unreachable;
    defer Dir.close(dir, io);

    const key = try create(dir, io);
    const loaded = try load(dir, io);
    try std.testing.expect(std.mem.eql(u8, &key, &loaded));

    // A second create on the same file is a conflict.
    try std.testing.expectError(error.AlreadyExists, create(dir, io));

    // The mode is 0600: owner read/write only.
    const st = Dir.statFile(dir, io, vault.KeyFileName, .{}) catch unreachable;
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "keyfile load errors" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = std.Io.Threaded.io(&threaded);
    const dir_path = try tempDir(io, gpa, "errors");
    defer {
        gpa.free(dir_path);
        Dir.deleteTree(Dir.cwd(), io, dir_path) catch {};
    }
    const dir = Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch unreachable;
    defer Dir.close(dir, io);

    try std.testing.expectError(error.KeyNotFound, load(dir, io));

    const f = dir.createFile(io, vault.KeyFileName, .{}) catch unreachable;
    File.writeStreamingAll(f, io, "short") catch unreachable;
    File.close(f, io);
    try std.testing.expectError(error.BadKeyFile, load(dir, io));
}
