//! zephyr derived status|rebuild — inspect or force-rebuild the derived
//! artifacts; `rebuild --embeddings` also builds the vector artifact
//! (it loads the model) (spec/semantic.md section 7).

const std = @import("std");
const core = @import("zephyr_core");
const embed_mod = @import("zephyr_embed");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");
const embed_helpers = @import("../embed_helpers.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn run(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    if (rest.len == 0 or rest.len > 2) return error.Usage;
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path, false);
    defer journal.close();
    const result = try cli_journal.verifyOrReport(arena, io, style, err_file, &journal);
    if (rest.len == 1 and std.mem.eql(u8, rest[0], "status")) {
        var report = try core.dstore.artifactStatus(arena, &journal, result);
        defer report.deinit();
        for (report.items) |a| {
            try output.printLine(out, io, try output.renderStatusLine(style, arena, a));
        }
    } else if (std.mem.eql(u8, rest[0], "rebuild")) {
        // `rebuild --embeddings` also builds the vector artifact (it loads
        // the model); without the flag, embed.zde is never touched
        // (spec/semantic.md section 7).
        const with_embeddings = rest.len == 2 and std.mem.eql(u8, rest[1], "--embeddings");
        if (rest.len == 2 and !with_embeddings) return error.Usage;
        const recs = try journal.collectPlaintext(arena);
        defer recs.deinit();
        const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
        defer visible.deinit();
        const counts = try core.dstore.rebuild(arena, &journal, &visible, result);
        try output.printLine(out, io, try arena.print(
            "{s}rebuilt · {d} {s} · {d} {s}",
            .{
                try style.okMark(arena),
                counts.word_count,
                output.countNoun(counts.word_count, "word", "words"),
                counts.entity_count,
                output.countNoun(counts.entity_count, "entity", "entities"),
            },
        ));
        if (with_embeddings) {
            const model_path = try embed_helpers.resolveModelPathOrReport(arena, io, style, err_file, environ_map);
            try embed_helpers.fetchDefaultModelIfNeeded(gpa, io, err_file, out, environ_map, model_path);
            const engine = embed_mod.create(arena, io, model_path) catch |err| {
                try embed_helpers.reportEmbedError(arena, io, style, err_file, model_path, err);
                return err;
            };
            defer engine.deinit();
            const ec = try core.dstore.rebuildEmbeddings(arena, &journal, &visible, result, engine);
            try output.printLine(out, io, try arena.print(
                "{s}embedded · {d} {s}",
                .{ try style.okMark(arena), ec.chunk_count, output.countNoun(ec.chunk_count, "entry", "entries") },
            ));
        }
    } else {
        return error.Usage;
    }
}
