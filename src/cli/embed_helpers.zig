//! Shared embedding-surface helpers for the CLI commands that load the
//! model (`rank`, `derived rebuild --embeddings`): resolving the pinned
//! model path, auto-fetching the model at the default location, and
//! reporting embedding-surface failures with an actionable message.
//! Commands import this file rather than each other (enforced by
//! test/structure.py).

const std = @import("std");
const embed_mod = @import("zephyr_embed");
const errors = @import("errors.zig");
const output = @import("output.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

/// The pinned model's path, with an actionable error when the environment
/// cannot name one (spec/semantic.md section 2). A relative
/// `$ZEPHYR_EMBED_MODEL` is resolved against the cwd: the engine (and the
/// fetcher) open the path with std's *Absolute entry points, which
/// assert.
pub fn resolveModelPathOrReport(
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

/// Auto-fetch (distribution): when the pinned model is missing or the
/// wrong size at the *default* location, download it now; a
/// `$ZEPHYR_EMBED_MODEL` path is never populated automatically. Stat-only
/// pre-check: a size-matching file is left to the engine's own hash gate
/// (which re-hashes the model on every load).
/// The download's own progress lines are plain (the fetcher stays free of
/// CLI styling); the failure lines here carry the `✗ ` mark as text.
pub fn fetchDefaultModelIfNeeded(
    gpa: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    model_path: []const u8,
) errors.RunError!void {
    if (environ_map.get(embed_mod.model.ModelEnv) != null) return;
    switch (try embed_mod.fetch.preCheck(io, model_path)) {
        .ok => return,
        .absent, .wrong_size => {},
    }
    embed_mod.fetch.downloadAndInstall(gpa, io, environ_map, out, model_path) catch |err| switch (err) {
        error.HashMismatch => {
            try output.printLine(err_file, io, "✗ model download failed: the file does not match the pinned sha256 (retry: zephyr model fetch)");
            return err;
        },
        error.BadResponse => {
            try output.printLine(err_file, io, "✗ model download failed: the server did not return the model (retry: zephyr model fetch)");
            return err;
        },
        else => |e| {
            try output.printLine(err_file, io, "✗ could not download the embedding model: check your network connection (then run: zephyr model fetch)");
            return e;
        },
    };
}

/// The actionable message for an embedding-surface failure
/// (spec/semantic.md sections 2, 7): it names the path, the pinned model,
/// and the download URL, and never a raw engine failure.
pub fn reportEmbedError(
    arena: Allocator,
    io: Io,
    style: output.Style,
    file: File,
    model_path: []const u8,
    err: embed_mod.CreateError,
) errors.RunError!void {
    const mark = try style.errMark(arena);
    switch (err) {
        error.EngineUnavailable => {
            try output.printLine(file, io, try arena.print(
                "{s}this zephyr build has no embedding engine (built with -Dno-embed=true)",
                .{mark},
            ));
            try output.printLine(file, io, "rebuild without the flag to enable embeddings");
            return;
        },
        error.ModelNotFound => {
            try output.printLine(file, io, try arena.print(
                "{s}embedding model not found at {s}",
                .{ mark, try style.dim(arena, model_path) },
            ));
        },
        error.ModelMismatch => {
            try output.printLine(file, io, try arena.print(
                "{s}embedding model at {s} does not match the pinned model",
                .{ mark, try style.dim(arena, model_path) },
            ));
        },
        error.ModelLoadFailed => {
            try output.printLine(file, io, try arena.print(
                "{s}the engine refused to load the embedding model",
                .{mark},
            ));
            return;
        },
        error.ContextInitFailed => {
            try output.printLine(file, io, try arena.print(
                "{s}the engine could not initialize the embedding model",
                .{mark},
            ));
            return;
        },
        else => return err,
    }
    const hex = try shaHex(arena);
    defer arena.free(hex);
    try output.printLine(file, io, try style.dim(arena, try arena.print(
        "expected: {d} bytes, sha256 {s}",
        .{ embed_mod.model.ModelBytes, hex },
    )));
    try output.printLine(file, io, try style.dim(arena, embed_mod.model.ModelDownloadUrl));
}

fn shaHex(allocator: Allocator) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, 64);
    for (embed_mod.model.ModelSha256, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}
