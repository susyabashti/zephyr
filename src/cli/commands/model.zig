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
    style: output.Style,
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
    const path = try resolvePath(arena, io, style, err_file, environ_map);

    if (std.mem.eql(u8, sub, "status")) {
        const check = try fetch.checkModel(io, path);
        try output.printLine(out, io, try statusLine(style, arena, check, path));
        if (environ_map.get(embed_mod.model.ModelEnv) != null) {
            try output.printLine(out, io, try style.dim(arena, "source: $ZEPHYR_EMBED_MODEL"));
        }
        return;
    }

    // fetch: skip the download only when the file is already verified
    // and --force was not given; a wrong-size or corrupt file is replaced.
    const check = try fetch.checkModel(io, path);
    if (!force and check.state() == .valid) {
        return output.printLine(out, io, try statusLine(style, arena, check, path));
    }
    return fetch.downloadAndInstall(gpa, io, environ_map, out, path) catch |err| switch (err) {
        error.HashMismatch => {
            try output.printLine(err_file, io, try arena.print(
                "{s}model download failed: the file does not match the pinned sha256 (retry: zephyr model fetch)",
                .{try style.errMark(arena)},
            ));
            return err;
        },
        error.BadResponse => {
            try output.printLine(err_file, io, try arena.print(
                "{s}model download failed: the server did not return the model (retry: zephyr model fetch)",
                .{try style.errMark(arena)},
            ));
            return err;
        },
        else => |e| {
            try output.printLine(err_file, io, try arena.print(
                "{s}model download failed: check your network connection (retry: zephyr model fetch)",
                .{try style.errMark(arena)},
            ));
            return e;
        },
    };
}

fn statusLine(style: output.Style, allocator: Allocator, check: fetch.Check, path: []const u8) Allocator.Error![]const u8 {
    const path_dim = try style.dim(allocator, path);
    return switch (check.state()) {
        .valid => allocator.print("{s}model ok (sha256 verified) · {s}", .{ try style.okMark(allocator), path_dim }),
        .invalid => allocator.print(
            "{s}model invalid ({d} bytes, expected {d}) (run: zephyr model fetch) · {s}",
            .{ try style.errMark(allocator), check.size, embed_mod.model.ModelBytes, path_dim },
        ),
        .absent => allocator.print("{s}model missing (run: zephyr model fetch) · {s}", .{ try style.errMark(allocator), path_dim }),
    };
}

/// The model's path; a relative `$ZEPHYR_EMBED_MODEL` is resolved against
/// the cwd, because the fetcher (and the engine) require absolute paths.
fn resolvePath(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    environ_map: *const std.process.Environ.Map,
) errors.RunError![]const u8 {
    const raw = embed_mod.model.resolveModelPath(arena, environ_map) catch |err| switch (err) {
        error.HomeNotFound => {
            try output.printLine(err_file, io, try arena.print(
                "{s}no embedding model path: set $ZEPHYR_EMBED_MODEL or $HOME",
                .{try style.errMark(arena)},
            ));
            return error.ModelNotFound;
        },
        else => |e| return e,
    };
    if (std.Io.Dir.path.isAbsolute(raw)) return raw;
    const cwd = try std.process.currentPathAlloc(io, arena);
    return try arena.print("{s}/{s}", .{ cwd, raw });
}
