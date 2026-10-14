//! zephyr model fetch [--force] | zephyr model status (distribution):
//! manage the pinned embedding model — `fetch` downloads and installs it
//! (a no-op when it is already verified, unless --force), and `status`
//! reports where it lives and whether it matches the pin. Works in
//! --no-embed builds too (pre-fetch the model for a later full build).

const std = @import("std");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
const embed_mod = @import("zephyr_embed");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

const fetch = embed_mod.fetch;

pub fn run(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    rest: []const []const u8,
) errors.RunError!void {
    if (rest.len == 0 or rest.len > 2) return error.Usage;
    const sub = rest[0];
    if (!std.mem.eql(u8, sub, "fetch") and !std.mem.eql(u8, sub, "status")) return error.Usage;
    const force = rest.len == 2 and std.mem.eql(u8, rest[1], "--force");
    if (rest.len == 2 and !force) return error.Usage;
    const path = try resolvePath(arena, io, err_file, environ_map);

    if (std.mem.eql(u8, sub, "status")) {
        const check = try fetch.checkModel(io, path);
        try output.printLine(out, io, try arena.print("path: {s}", .{path}));
        if (environ_map.get(embed_mod.model.ModelEnv) != null) {
            try output.printLine(out, io, "source: $ZEPHYR_EMBED_MODEL");
        }
        try output.printLine(out, io, try statusLine(arena, check));
        return;
    }

    // fetch: skip the download only when the file is already verified
    // and --force was not given; a wrong-size or corrupt file is replaced.
    const check = try fetch.checkModel(io, path);
    if (!force and check.state() == .valid) {
        return output.printLine(out, io, try arena.print("model: ok (sha256 verified) at {s}", .{path}));
    }
    return fetch.downloadAndInstall(gpa, io, environ_map, out, path) catch |err| switch (err) {
        error.HashMismatch => {
            try output.printLine(err_file, io, "model download failed: the file does not match the pinned sha256 (retry: zephyr model fetch)");
            return err;
        },
        error.BadResponse => {
            try output.printLine(err_file, io, "model download failed: the server did not return the model (retry: zephyr model fetch)");
            return err;
        },
        else => |e| {
            try output.printLine(err_file, io, "model download failed: check your network connection (retry: zephyr model fetch)");
            return e;
        },
    };
}

fn statusLine(allocator: Allocator, check: fetch.Check) Allocator.Error![]const u8 {
    return switch (check.state()) {
        .valid => allocator.print("status: ok ({d} bytes, sha256 verified)", .{check.size}),
        .invalid => allocator.print(
            "status: invalid ({d} bytes, expected {d}) (run: zephyr model fetch)",
            .{ check.size, embed_mod.model.ModelBytes },
        ),
        .absent => "status: missing (run: zephyr model fetch)",
    };
}

/// The model's path; a relative `$ZEPHYR_EMBED_MODEL` is resolved against
/// the cwd, because the fetcher (and the engine) require absolute paths.
fn resolvePath(
    arena: Allocator,
    io: Io,
    err_file: File,
    environ_map: *const std.process.Environ.Map,
) errors.RunError![]const u8 {
    const raw = embed_mod.model.resolveModelPath(arena, environ_map) catch |err| switch (err) {
        error.HomeNotFound => {
            try output.printLine(err_file, io, "no embedding model path: set $ZEPHYR_EMBED_MODEL or $HOME");
            return error.ModelNotFound;
        },
        else => |e| return e,
    };
    if (std.Io.Dir.path.isAbsolute(raw)) return raw;
    const cwd = try std.process.currentPathAlloc(io, arena);
    return try arena.print("{s}/{s}", .{ cwd, raw });
}
