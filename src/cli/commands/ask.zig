//! zephyr ask [from:to] <question...> — the deterministic context pack for
//! the user's AI (spec/derived.md section 7): provenance, question,
//! profile, notes, period digest, matches. Hybrid retrieval (spec/semantic.md
//! section 6) when the vector artifact is fresh and the model is available;
//! any failure degrades silently to the keyword list — `ask` never fails
//! over embeddings.

const std = @import("std");
const core = @import("zephyr_core");
const embed_mod = @import("zephyr_embed");
const errors = @import("../errors.zig");
const args = @import("../args.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn run(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    // Optional leading period: YYYY-MM-DD or YYYY-MM-DD:YYYY-MM-DD.
    var range: ?core.view.DayRange = null;
    var question_args = rest;
    if (rest.len > 0) {
        if (args.parseDayRange(rest[0])) |r| {
            range = r;
            question_args = rest[1..];
        }
    }
    const question = try args.joinParts(arena, question_args);
    if (question.len == 0) return error.Usage;
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    // Period: the explicit range, else a YYYY-MM-DD in the question, else
    // the current week (spec/derived.md section 7, step 4).
    const pack_range = try core.dstore.resolveRange(io, &journal, range, question);
    // Hybrid retrieval when the vector artifact is fresh and the model is
    // available; any failure degrades silently to the keyword list
    // (spec/semantic.md section 6) — `ask` never fails over embeddings.
    var hybrid: ?core.dstore.Hybrid = null;
    const embed_store = try core.dstore.loadFreshEmbed(arena, &journal, result);
    if (embed_store) |store| {
        defer store.deinit();
        const model_path = embed_mod.model.resolveModelPath(arena, environ_map) catch null;
        if (model_path) |p| {
            const engine = embed_mod.create(arena, io, p) catch null;
            if (engine) |e| {
                defer e.deinit();
                // An artifact built under a different model or engine is
                // stale, never served: degrade to the keyword list.
                if (core.embed.matchesEngine(&store, e)) {
                    const vectors = e.embed(arena, &.{question}, .query) catch null;
                    if (vectors) |vs| {
                        defer {
                            for (vs) |v| arena.free(v);
                            arena.free(vs);
                        }
                        // Copy the query vector: its lifetime must not ride on
                        // the engine's per-call allocation.
                        const qv = try arena.alloc(f32, vs[0].len);
                        @memcpy(qv, vs[0]);
                        hybrid = .{ .store = &store, .query = qv };
                    }
                }
            }
        }
    }
    const pack = try core.dstore.contextPack(arena, &journal, &visible, result, question, pack_range, true, hybrid);
    try output.printBlock(out, io, pack);
}
