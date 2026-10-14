//! The pinned embedding model (spec/semantic.md section 2): the file name,
//! size, sha256, download URL, and path resolution. Pure configuration —
//! no engine code — shared by the llama.cpp engine and the CLI error
//! messages, so the pin lives in exactly one place.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ModelFile = "embeddinggemma-300M-Q8_0.gguf";
pub const ModelEnv = "ZEPHYR_EMBED_MODEL";
pub const ModelBytes: u64 = 328_577_056;
pub const ModelSha256: [32]u8 = hex32(
    "a0f7b4e13c397a6e1b32c2de75b1f65a14c92ec524d5f674d94a4290a1c4969b",
);
pub const ModelDownloadUrl = "https://huggingface.co/unsloth/embeddinggemma-300M-GGUF/resolve/main/" ++
    ModelFile;

/// Resolution order: `$ZEPHYR_EMBED_MODEL`, else
/// `~/.zephyr/models/<ModelFile>` (HOME from the environment). The caller
/// frees the returned slice.
pub fn resolveModelPath(
    allocator: Allocator,
    environ_map: *const std.process.Environ.Map,
) (Allocator.Error || error{HomeNotFound})![]const u8 {
    if (environ_map.get(ModelEnv)) |p| return try allocator.dupe(u8, p);
    const home = environ_map.get("HOME") orelse return error.HomeNotFound;
    return try allocator.print("{s}/.zephyr/models/{s}", .{ home, ModelFile });
}

fn hex32(comptime s: []const u8) [32]u8 {
    if (s.len != 64) @compileError("a sha256 hex string is 64 characters");
    var out: [32]u8 = undefined;
    for (out, 0..) |_, i| {
        out[i] = (hexVal(s[i * 2]) << 4) | hexVal(s[i * 2 + 1]);
    }
    return out;
}

fn hexVal(comptime c: u8) u8 {
    return if (c >= '0' and c <= '9') c - '0' else c - 'a' + 10;
}
