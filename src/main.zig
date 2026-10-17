const std = @import("std");
const cli = @import("cli/cli.zig");
const output = @import("cli/output.zig");

const File = std.Io.File;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    cli.run(init, args) catch |err| switch (err) {
        // cli.run already printed the details.
        error.Usage, error.TargetNotFound, error.TargetNotEntry, error.SegmentNotSealed => std.process.exit(2),
        error.VerifyFailed, error.JournalNotFound, error.BadOtsProof => std.process.exit(1),
        // Encryption (spec/encryption.md): the journal cannot be opened at
        // all — the key is missing, locked behind the keychain, or corrupt.
        error.KeyNotFound, error.KeychainUnavailable, error.KeyCorrupt => std.process.exit(1),
        // Phase 8: the embedding surface. Config/model-placement problems
        // are the user's to act on (exit 2, like usage); engine failures
        // are runtime faults (exit 1).
        error.EmbeddingsUnavailable, error.EngineUnavailable, error.ModelNotFound, error.ModelMismatch => std.process.exit(2),
        error.ModelLoadFailed, error.ContextInitFailed, error.DecodeFailed, error.SequenceTooLong => std.process.exit(1),
        // Distribution: the model download failed (server, network, or the
        // bytes did not match the pin).
        error.BadResponse, error.HashMismatch, error.ParentDirNotFound => std.process.exit(1),
        else => {
            const style = output.Style.detect(File.stderr(), init.io, init.environ_map);
            std.debug.print("{s}zephyr: {s}\n", .{ try style.errMark(arena), @errorName(err) });
            std.process.exit(1);
        },
    };
}
