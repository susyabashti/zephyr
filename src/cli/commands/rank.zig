//! zephyr rank <query...> [--mode keyword|vector|hybrid] [--top N]
//! (spec/semantic.md section 7): ranked retrieval over the visible entries
//! — `keyword` (Phase 7 token hits), `vector` (cosine top-N over the fresh
//! artifact), or `hybrid` (RRF of the two, the default). Verify-first like
//! every command.
//!
//! Defaults: hybrid, N = 10. A provenance line, then one line per hit:
//!
//!   <rank>\t<seq>\t<score, 6 decimals>\t<view line>
//!
//! `vector` and `hybrid` need the fresh embedding artifact and the model;
//! without them they report where to build it and fail with
//! error.EmbeddingsUnavailable. `keyword` needs only the journal.

const std = @import("std");
const core = @import("zephyr_core");
const embed_mod = @import("zephyr_embed");
const errors = @import("../errors.zig");
const args = @import("../args.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");
const embed_helpers = @import("../embed_helpers.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

const journal_mod = core.journal;
const view = core.view;
const embed = core.embed;

const DefaultTop: usize = 10;

const Mode = enum { keyword, vector, hybrid };

pub fn run(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    var mode: Mode = .hybrid;
    var top: usize = DefaultTop;
    var words = std.ArrayList([]const u8).empty;
    errdefer words.deinit(arena);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            mode = parseMode(rest[i]) orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            top = std.fmt.parseInt(usize, rest[i], 10) catch return error.Usage;
            if (top == 0) return error.Usage;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.Usage;
        } else {
            try words.append(arena, arg);
        }
    }
    const question = try args.joinParts(arena, words.items);
    if (question.len == 0) return error.Usage;

    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();

    // seq -> visible entry, for the view-line column.
    var by_seq = std.array_hash_map.Auto(u64, *const view.ViewEntry).empty;
    defer by_seq.deinit(arena);
    for (visible.entries) |*e| try by_seq.put(arena, e.seq, e);

    if (mode == .keyword) {
        // Keyword mode never touches the model or the artifact.
        const kw = try embed.keywordHits(arena, &visible, question);
        defer arena.free(kw);
        return renderHits(arena, io, out, result, &by_seq, kw[0..@min(top, kw.len)]);
    }

    // Vector and hybrid: the fresh artifact, or a clean, actionable error.
    const store = (try core.dstore.loadFreshEmbed(arena, &journal, result)) orelse {
        try output.printLine(err_file, io, "no fresh embedding artifact (run: zephyr derived rebuild --embeddings)");
        return error.EmbeddingsUnavailable;
    };
    defer store.deinit();

    const model_path = try embed_helpers.resolveModelPathOrReport(arena, io, err_file, environ_map);
    try embed_helpers.fetchDefaultModelIfNeeded(gpa, io, err_file, out, environ_map, model_path);
    const engine = embed_mod.create(arena, io, model_path) catch |err| {
        try embed_helpers.reportEmbedError(arena, io, err_file, model_path, err);
        return err;
    };
    defer engine.deinit();
    // An artifact built under a different model or engine is stale and
    // never served (spec/semantic.md section 5).
    if (!embed.matchesEngine(&store, engine)) {
        try output.printLine(err_file, io, "embedding artifact built under a different model or engine (run: zephyr derived rebuild --embeddings)");
        return error.EmbeddingsUnavailable;
    }
    const qv = engine.embed(arena, &.{question}, .query) catch |err| {
        try embed_helpers.reportEmbedError(arena, io, err_file, model_path, err);
        return err;
    };
    defer {
        for (qv) |v| arena.free(v);
        arena.free(qv);
    }
    const qvec = qv[0];

    const vec = try embed.cosineTopN(arena, store.seqs, store.vectors, store.dim, qvec, store.seqs.len);
    defer arena.free(vec);
    if (mode == .vector) {
        return renderHits(arena, io, out, result, &by_seq, vec[0..@min(top, vec.len)]);
    }

    // Hybrid: RRF of the two ranked lists, then top-N.
    const kw = try embed.keywordHits(arena, &visible, question);
    defer arena.free(kw);
    const kw_seqs = try seqsOf(arena, kw);
    defer arena.free(kw_seqs);
    const vec_seqs = try seqsOf(arena, vec);
    defer arena.free(vec_seqs);
    const fused = try embed.rrfFusion(arena, kw_seqs, vec_seqs);
    defer arena.free(fused);
    return renderHits(arena, io, out, result, &by_seq, fused[0..@min(top, fused.len)]);
}

/// The provenance line (the pack's shape) and one line per hit; entries
/// absent from the visible set (a stale artifact cannot happen here, but
/// neither can a redaction after the build) are skipped, not padded.
fn renderHits(
    arena: Allocator,
    io: Io,
    out: File,
    result: journal_mod.VerifyResult,
    by_seq: *const std.array_hash_map.Auto(u64, *const view.ViewEntry),
    hits: []const embed.RankHit,
) errors.RunError!void {
    const head_hex = try output.hexOf(arena, &result.head);
    defer arena.free(head_hex);
    const last_seq: u64 = if (result.record_count == 0) 0 else result.record_count - 1;
    try output.printLine(out, io, try arena.print("# zephyr: seq 0..{d} head={s}", .{ last_seq, head_hex }));
    for (hits, 0..) |hit, i| {
        const e = by_seq.get(hit.seq) orelse continue;
        const line = try view.entryLine(arena, e.*);
        defer arena.free(line);
        try output.printLine(out, io, try arena.print("{d}\t{d}\t{d:.6}\t{s}", .{ i + 1, hit.seq, hit.score, line }));
    }
}

fn parseMode(s: []const u8) ?Mode {
    if (std.mem.eql(u8, s, "keyword")) return .keyword;
    if (std.mem.eql(u8, s, "vector")) return .vector;
    if (std.mem.eql(u8, s, "hybrid")) return .hybrid;
    return null;
}

fn seqsOf(allocator: Allocator, hits: []const embed.RankHit) Allocator.Error![]u64 {
    const out = try allocator.alloc(u64, hits.len);
    for (out, hits) |*s, h| s.* = h.seq;
    return out;
}
