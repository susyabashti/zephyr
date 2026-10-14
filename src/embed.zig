//! The embedding engine module (spec/semantic.md sections 2-4), the CLI
//! layer's home for the llama.cpp binding.
//!
/// The default build links the pinned llama.cpp library and `create` loads
/// the hash-pinned model. `zig build -Dno-embed=true` compiles no engine
/// code at all: `create` reports `error.EngineUnavailable` and the embedding
/// surface degrades while every other command works. `zig build test` never
/// needs the engine — the core-side tests supply a deterministic fake.
const std = @import("std");
const options = @import("embed_options");
const core = @import("zephyr_core");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The engine interface core sees (core/embed.zig): both the llama.cpp
/// implementation and the stub satisfy it.
pub const Engine = core.embed.Engine;
pub const EmbedError = core.embed.EmbedError;

/// The pinned model: file, size, sha256, download URL, path resolution.
/// No engine code — available in `--no-embed` builds for the CLI messages.
pub const model = @import("embed/model.zig");

/// The model fetcher: downloads the pinned model, verifies it against
/// the pin, and installs it. Std-only — available in `--no-embed`
/// builds too (it can pre-fetch the model there).
pub const fetch = @import("embed/fetch.zig");

pub const FetchError = fetch.FetchError;

pub const CreateError = if (options.has_embed)
    @import("embed/engine.zig").CreateError
else
    EmbedError;

pub const create: *const fn (Allocator, Io, []const u8) CreateError!Engine =
    if (options.has_embed) @import("embed/engine.zig").create else createUnavailable;

/// `-Dno-embed=true`: the embedding surface is unavailable; everything
/// else works (spec/semantic.md section 2).
fn createUnavailable(allocator: Allocator, io: Io, model_path: []const u8) CreateError!Engine {
    _ = allocator;
    _ = io;
    _ = model_path;
    return error.EngineUnavailable;
}
