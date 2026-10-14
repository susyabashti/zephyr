//! CLI: zephyr <text>  |  zephyr log [-t TAG]... <text>  |  zephyr verify
//!     zephyr today | yesterday | week | on YYYY-MM-DD  |  zephyr search <q>
//!     zephyr ask [from:to] <question...>  |  zephyr recap [start..end]
//!     zephyr profile  |  zephyr derived status|rebuild
//!     zephyr edit <seq> [-t TAG]... "text"  |  zephyr rm <seq>
//!     zephyr redact <seq> [--yes]  |  zephyr checkpoint [--key PATH]
//!     zephyr export --for-ai [YYYY-MM-DD[:YYYY-MM-DD]]
//!     zephyr ots-stamp <segment> --proof <path>  |  zephyr ots-export <segment> [--out <path>]
//!
//! Exit codes: 0 ok, 1 integrity or journal error, 2 usage error.

const std = @import("std");
const core = @import("zephyr_core");
const mcp = @import("zephyr_mcp");
const embed_mod = @import("zephyr_embed");
const rank = @import("rank.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const Version: []const u8 = "0.2.0";

pub const RunError = error{
    Usage,
    VerifyFailed,
    JournalNotFound,
    TargetNotFound,
    TargetNotEntry,
    BadKeyFile,
    BadOtsProof,
    SegmentNotSealed,
} || core.anchor.SignError || core.journal.OpenError || core.journal.Journal.AppendError ||
    core.journal.Journal.VerifyError || core.journal.Journal.RedactError ||
    core.journal.Journal.CheckAnchorsError || core.journal.Journal.WriteAnchorError ||
    core.journal.Journal.CheckOtsAnchorsError || core.journal.Journal.OtsCheckFailure ||
    core.ots.VerifyError ||
    core.view.RenderError || core.dstore.PackError || core.dstore.StatusError ||
    core.dstore.RebuildError || File.OpenError || File.Writer.Error || std.Io.Reader.ShortError ||
    std.crypto.errors.IdentityElementError || std.process.CurrentPathError || mcp.server.RunError ||
    rank.RankError; // Phase 8: the embedding surface (rank, ask hybrid, derived rebuild --embeddings)

pub fn run(init: std.process.Init, args: []const []const u8) RunError!void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const out = File.stdout();
    const err_file = File.stderr();

    var journal_path: ?[]const u8 = null;
    var i: usize = 1;
    // Global options before the command.
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--journal")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            journal_path = args[i];
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try printLine(out, io, "zephyr " ++ Version ++ " (format v1)");
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
            try printUsage(err_file, io);
            return;
        } else {
            break;
        }
    }
    if (i >= args.len) {
        try printUsage(err_file, io);
        return error.Usage;
    }
    const command = args[i];

    // A bare word (not a known command) is a quick log; the word itself is the
    // first part of the text, so `rest` starts at `command`, not after it.
    if (isCommand(command)) {
        const rest = args[i + 1 ..];
        const path = try resolveJournalPath(arena, io, init.environ_map, journal_path);
        if (std.mem.eql(u8, command, "log")) {
            const seq = try runLog(arena, gpa, io, init.environ_map, path, rest);
            try printLine(out, io, try arena.print("logged seq {d}", .{seq}));
        } else if (std.mem.eql(u8, command, "verify")) {
            try runVerify(arena, io, err_file, out, init.environ_map, path);
        } else if (std.mem.eql(u8, command, "today") or std.mem.eql(u8, command, "yesterday") or std.mem.eql(u8, command, "week")) {
            try runDayView(arena, io, err_file, out, init.environ_map, path, command);
        } else if (std.mem.eql(u8, command, "on")) {
            if (rest.len != 1) return error.Usage;
            const day = parseCivilDate(rest[0]) orelse return error.Usage;
            try runRangeView(arena, io, err_file, out, init.environ_map, path, .{ .start = day, .end = day + 1 });
        } else if (std.mem.eql(u8, command, "export")) {
            try runExport(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "search")) {
            try runSearch(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "ask")) {
            try runAsk(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "recap")) {
            try runRecap(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "profile")) {
            try runProfile(arena, io, err_file, out, init.environ_map, path);
        } else if (std.mem.eql(u8, command, "derived")) {
            try runDerived(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "rank")) {
            try rank.run(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "edit")) {
            try runEdit(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "rm")) {
            try runRm(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "redact")) {
            try runRedact(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "checkpoint")) {
            try runCheckpoint(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "ots-stamp")) {
            try runOtsStamp(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "ots-export")) {
            try runOtsExport(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "mcp")) {
            try runMcp(arena, io, err_file, init.environ_map, path, rest);
        } else {
            unreachable;
        }
    } else {
        const path = try resolveJournalPath(arena, io, init.environ_map, journal_path);
        const seq = try runLog(arena, gpa, io, init.environ_map, path, args[i..]);
        try printLine(out, io, try arena.print("logged seq {d}", .{seq}));
    }
}

fn isCommand(s: []const u8) bool {
    return std.mem.eql(u8, s, "log") or std.mem.eql(u8, s, "verify") or
        std.mem.eql(u8, s, "today") or std.mem.eql(u8, s, "yesterday") or
        std.mem.eql(u8, s, "week") or std.mem.eql(u8, s, "on") or
        std.mem.eql(u8, s, "search") or std.mem.eql(u8, s, "ask") or
        std.mem.eql(u8, s, "recap") or std.mem.eql(u8, s, "profile") or
        std.mem.eql(u8, s, "derived") or std.mem.eql(u8, s, "edit") or
        std.mem.eql(u8, s, "rm") or std.mem.eql(u8, s, "redact") or
        std.mem.eql(u8, s, "checkpoint") or std.mem.eql(u8, s, "export") or
        std.mem.eql(u8, s, "ots-stamp") or std.mem.eql(u8, s, "ots-export") or
        std.mem.eql(u8, s, "mcp") or std.mem.eql(u8, s, "rank");
}

// ---------------------------------------------------------------- log

fn runLog(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!u64 {
    var parsed = try parseArgs(gpa, rest);
    defer parsed.deinit(gpa);
    const text = try joinParts(arena, parsed.parts.items);
    if (text.len == 0) {
        try printUsage(File.stderr(), io);
        return error.Usage;
    }
    const now_ms = nowMs(io);
    const journal = try core.journal.Journal.open(arena, io, environ_map, path, true);
    defer journal.close();
    // Verify before trust: never extend a failing journal.
    const pre = try journal.verify(arena);
    if (!pre.ok) {
        try reportIssue(File.stderr(), io, arena, pre.issue.?);
        return error.VerifyFailed;
    }
    const tz_offset_min = try journal.tzOffsetMinutesAtMs(now_ms);
    return journal.appendRecord(
        arena,
        core.records.RecordType.entry,
        0,
        text,
        parsed.tags.items,
        now_ms,
        tz_offset_min,
        false,
    );
}

// ---------------------------------------------------------------- views

fn runDayView(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    which: []const u8,
) RunError!void {
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);
    // "Today" is the current civil day in the local timezone.
    const now_ms = nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const today = try core.view.localDay(now_ms, offset);
    const range = if (std.mem.eql(u8, which, "today"))
        core.view.DayRange{ .start = today, .end = today + 1 }
    else if (std.mem.eql(u8, which, "yesterday"))
        core.view.DayRange{ .start = today - 1, .end = today }
    else blk: {
        // ISO week: Monday through Sunday containing today.
        const monday = core.view.weekStart(today);
        break :blk core.view.DayRange{ .start = monday, .end = monday + 7 };
    };
    try renderJournalRange(arena, &journal, out, io, range);
}

fn runRangeView(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    range: core.view.DayRange,
) RunError!void {
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);
    try renderJournalRange(arena, &journal, out, io, range);
}

fn renderJournalRange(arena: Allocator, journal: *const core.journal.Journal, out: File, io: Io, range: core.view.DayRange) RunError!void {
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const rendered = try core.view.renderRange(arena, recs.headers, recs.payloads, range);
    try printBlock(out, io, rendered);
}

fn runSearch(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    const query = try joinParts(arena, rest);
    if (query.len == 0) return error.Usage;
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    const matches = try core.search.find(arena, &visible, query);
    defer arena.free(matches);
    const rendered = try core.search.render(arena, matches, query);
    try printBlock(out, io, rendered);
}

// ---------------------------------------------------------------- derived layer (Phase 7)

fn runAsk(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    // Optional leading period: YYYY-MM-DD or YYYY-MM-DD:YYYY-MM-DD.
    var range: ?core.view.DayRange = null;
    var question_args = rest;
    if (rest.len > 0) {
        if (parseDayRange(rest[0])) |r| {
            range = r;
            question_args = rest[1..];
        }
    }
    const question = try joinParts(arena, question_args);
    if (question.len == 0) return error.Usage;
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try verifyOrReport(arena, io, err_file, &journal);
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
    try printBlock(out, io, pack);
}

/// The Mon-Sun week containing now, under the journal's timezone.
fn currentWeek(journal: *const core.journal.Journal) RunError!core.view.DayRange {
    const now_ms = nowMs(journal.io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const today = try core.view.localDay(now_ms, offset);
    const monday = core.view.weekStart(today);
    return core.view.DayRange{ .start = monday, .end = monday + 7 };
}

/// `YYYY-MM-DD..YYYY-MM-DD` (inclusive) or a single `YYYY-MM-DD`.
fn parseDotDayRange(s: []const u8) ?core.view.DayRange {
    const split = std.mem.indexOf(u8, s, "..") orelse {
        const day = parseCivilDate(s) orelse return null;
        return core.view.DayRange{ .start = day, .end = day + 1 };
    };
    const start = parseCivilDate(s[0..split]) orelse return null;
    const end = parseCivilDate(s[split + 2 ..]) orelse return null;
    if (end < start) return null;
    return core.view.DayRange{ .start = start, .end = end + 1 };
}

fn runRecap(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    if (rest.len > 1) return error.Usage;
    var range: ?core.view.DayRange = null;
    if (rest.len == 1) {
        range = parseDotDayRange(rest[0]) orelse return error.Usage;
    }
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    if (range == null) range = try currentWeek(&journal);
    const digest = try core.dstore.digestOrRebuild(arena, &journal, &visible, range.?, result);
    try printBlock(out, io, digest);
}

fn runProfile(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
) RunError!void {
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    const doc = try core.dstore.profileWithNotes(arena, &journal, &visible, result);
    try printBlock(out, io, doc);
}

fn runDerived(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    if (rest.len == 0 or rest.len > 2) return error.Usage;
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try verifyOrReport(arena, io, err_file, &journal);
    if (rest.len == 1 and std.mem.eql(u8, rest[0], "status")) {
        var report = try core.dstore.artifactStatus(arena, &journal, result);
        defer report.deinit();
        for (report.items) |a| {
            try printLine(out, io, try renderStatusLine(arena, a));
        }
    } else if (std.mem.eql(u8, rest[0], "rebuild")) {
        // `rebuild --embeddings` also builds the vector artifact (it loads
        // the model); without the flag, embed.zde is never touched
        // (spec/semantic.md section 7).
        const with_embeddings = rest.len == 2 and std.mem.eql(u8, rest[1], "--embeddings");
        if (rest.len == 2 and !with_embeddings) return error.Usage;
        const recs = try journal.collectRecords(arena);
        defer recs.deinit();
        const visible = try core.view.visibleEntries(arena, recs.headers, recs.payloads);
        defer visible.deinit();
        const counts = try core.dstore.rebuild(arena, &journal, &visible, result);
        try printLine(out, io, try arena.print(
            "rebuilt: {d} words, {d} entities (digests regenerate on demand)",
            .{ counts.word_count, counts.entity_count },
        ));
        if (with_embeddings) {
            const model_path = try rank.resolveModelPathOrReport(arena, io, err_file, environ_map);
            const engine = embed_mod.create(arena, io, model_path) catch |err| {
                try rank.reportEmbedError(arena, io, err_file, model_path, err);
                return err;
            };
            defer engine.deinit();
            const ec = try core.dstore.rebuildEmbeddings(arena, &journal, &visible, result, engine);
            try printLine(out, io, try arena.print(
                "embeddings: {d} entries, {d} bytes/entry (derived/embed.zde)",
                .{ ec.chunk_count, ec.bytes_per_entry },
            ));
        }
    } else {
        return error.Usage;
    }
}

fn renderStatusLine(arena: Allocator, a: core.dstore.Artifact) Allocator.Error![]const u8 {
    // The embedding artifact carries its own digests (spec/semantic.md
    // section 7): hex12 head, model, and engine plus the dimension.
    const line = if (a.dim != null) blk: {
        const head = if (a.head) |h| try hex12Of(arena, &h) else "-";
        const model = if (a.model_hash) |m| try hex12Of(arena, &m) else "-";
        const engine = if (a.engine_id) |e| try hex12Of(arena, &e) else "-";
        const records = if (a.record_count) |r| r else 0;
        break :blk try arena.print(
            "{s}  head={s}  dim={d}  model={s}  engine={s}  records={d}",
            .{ a.name, head, a.dim.?, model, engine, records },
        );
    } else blk: {
        const head = if (a.head) |h| try hexOf(arena, &h) else "-";
        var l = try arena.print("{s}  head={s}", .{ a.name, head });
        if (a.version) |v| {
            const extra = try arena.print("  v{d}  {d} records", .{ v, a.record_count.? });
            l = try arena.print("{s}{s}", .{ l, extra });
        }
        break :blk l;
    };
    const state = switch (a.state) {
        .fresh => "fresh",
        .stale => "stale",
        .corrupt => "corrupt",
        .missing => "missing",
    };
    return try arena.print("{s}  {s}", .{ line, state });
}

// ---------------------------------------------------------------- edit / rm

fn runEdit(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    if (rest.len == 0) return error.Usage;
    const target = std.fmt.parseInt(u64, rest[0], 10) catch return error.Usage;
    var parsed = try parseArgs(arena, rest[1..]);
    defer parsed.deinit(arena);
    const text = try joinParts(arena, parsed.parts.items);
    if (text.len == 0) {
        try printUsage(File.stderr(), io);
        return error.Usage;
    }
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const target_header = core.journal.Journal.resolveEditTarget(recs.headers, target) catch |err| {
        try reportTargetError(arena, io, err_file, target, err);
        return switch (err) {
            error.TargetNotFound => error.TargetNotFound,
            error.TargetNotEntry => error.TargetNotEntry,
        };
    };
    // An amendment carries the entry's tags unless the user gives new ones,
    // so a plain text edit never silently drops tags.
    const tags = if (parsed.tags.items.len == 0)
        try effectiveTagsOf(arena, recs, target)
    else
        parsed.tags.items;
    const now_ms = nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const seq = try journal.appendRecord(
        arena,
        core.records.RecordType.amendment,
        target,
        text,
        tags,
        now_ms,
        offset,
        target_header.isPrivate(),
    );
    try printLine(out, io, try arena.print("amended seq {d} (new seq {d})", .{ target, seq }));
}

fn runRm(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    if (rest.len != 1) return error.Usage;
    const target = std.fmt.parseInt(u64, rest[0], 10) catch return error.Usage;
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);
    const recs = try journal.collectRecords(arena);
    defer recs.deinit();
    const target_header = core.journal.Journal.resolveEditTarget(recs.headers, target) catch |err| {
        try reportTargetError(arena, io, err_file, target, err);
        return switch (err) {
            error.TargetNotFound => error.TargetNotFound,
            error.TargetNotEntry => error.TargetNotEntry,
        };
    };
    const now_ms = nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const seq = try journal.appendRecord(
        arena,
        core.records.RecordType.tombstone,
        target,
        "",
        &.{},
        now_ms,
        offset,
        target_header.isPrivate(),
    );
    try printLine(out, io, try arena.print("tombstoned seq {d} (new seq {d})", .{ target, seq }));
}

// ---------------------------------------------------------------- redact

fn runRedact(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    if (rest.len < 1 or rest.len > 2) return error.Usage;
    const target = std.fmt.parseInt(u64, rest[0], 10) catch return error.Usage;
    var assume_yes = false;
    if (rest.len == 2) {
        if (!std.mem.eql(u8, rest[1], "--yes")) return error.Usage;
        assume_yes = true;
    }
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);
    if (!assume_yes) {
        const proceed = try confirmRedact(arena, io, out, target);
        if (!proceed) {
            try printLine(out, io, "aborted");
            return;
        }
    }
    const now_ms = nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const seq = try journal.redact(arena, target, now_ms, offset);
    try printLine(out, io, try arena.print("redacted seq {d} (redaction seq {d})", .{ target, seq }));
}

/// Prints the warning prompt and reads one line from stdin. Anything other
/// than y/Y aborts the redaction.
fn confirmRedact(arena: Allocator, io: Io, out: File, target: u64) RunError!bool {
    const prompt_fmt =
        \\redact seq {d}? the entry's text and tags are removed from the file; the
        \\record header and hash chain are kept, so the redaction itself is visible.
        \\\Proceed? [y/N]
    ;
    const prompt = try arena.print(prompt_fmt, .{target});
    try File.writeStreamingAll(out, io, prompt);
    const stdin = File.stdin();
    var stream_buf: [4096]u8 = undefined;
    var line_buf: [16]u8 = undefined;
    var reader = File.reader(stdin, io, &stream_buf);
    const n = try std.Io.Reader.readSliceShort(&reader.interface, &line_buf);
    if (n == 0) return false;
    var end = n;
    if (line_buf[end - 1] == '\n') end -= 1;
    if (end > 0 and line_buf[end - 1] == '\r') end -= 1;
    return std.mem.eql(u8, line_buf[0..end], "y") or std.mem.eql(u8, line_buf[0..end], "Y");
}

// ---------------------------------------------------------------- checkpoint

fn runCheckpoint(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    var key_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--key")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            key_path = rest[i];
        } else {
            return error.Usage;
        }
    }
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);

    // Key resolution: --key PATH > $ZEPHYR_KEY > <journal>/zephyr-key.
    const resolved_key = key_path orelse environ_map.get("ZEPHYR_KEY") orelse
        try arena.print("{s}/zephyr-key", .{path});
    const seed = try loadOrCreateKey(arena, io, resolved_key);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const now_ms = nowMs(io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const seq = try journal.appendRecord(arena, .checkpoint, 0, "", &.{}, now_ms, offset, false);

    // Anchor only a verified state: re-verify after the append and bind the
    // resulting (head, count) to the key.
    const result = try journal.verify(arena);
    if (!result.ok) {
        try reportIssue(err_file, io, arena, result.issue.?);
        return error.VerifyFailed;
    }
    const bytes = try core.anchor.render(&kp, result.head, result.record_count, now_ms, seq);
    try journal.writeAnchorFile(arena, seq, &bytes);
    try printLine(out, io, try arena.print(
        "checkpoint seq {d} (key {s}, anchor anchors/checkpoint-{d}.zpa)",
        .{ seq, resolved_key, seq },
    ));
}

/// Reads the 32-byte signing seed from the key file, or on first use
/// generates it from the OS CSPRNG and stores it with 0600 permissions.
fn loadOrCreateKey(allocator: Allocator, io: Io, key_path: []const u8) RunError![32]u8 {
    var seed: [32]u8 = undefined;
    const d = if (std.fs.path.dirname(key_path)) |parent|
        try Dir.openDirAbsolute(io, parent, .{})
    else
        Dir.cwd();
    defer Dir.close(d, io);
    const file_name = std.fs.path.basename(key_path);
    const existing = Dir.readFileAlloc(d, io, file_name, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        if (bytes.len != 32) return error.BadKeyFile;
        @memcpy(&seed, bytes);
        return seed;
    }
    try Io.randomSecure(io, &seed);
    const key_file = Dir.createFile(d, io, file_name, .{
        .permissions = File.Permissions.fromMode(0o600),
    }) catch |err| switch (err) {
        else => return err,
    };
    defer File.close(key_file, io);
    try File.writeStreamingAll(key_file, io, &seed);
    return seed;
}

/// The tags the view currently shows for entry `seq`: the latest amendment's
/// tags, or the entry's own. Arena-allocated; borrows the payload bytes.
fn effectiveTagsOf(
    arena: Allocator,
    recs: core.journal.Journal.RecordSet,
    target: u64,
) (Allocator.Error || core.records.DecodePayloadError)![]const []const u8 {
    var result: ?[]const []const u8 = null;
    for (recs.headers, recs.payloads) |h, payload| {
        const interesting = (h.record_type == .entry and h.seq == target) or
            (h.record_type == .amendment and h.target_seq == target);
        if (!interesting) continue;
        const decoded = try core.records.decodePayload(arena, payload);
        result = decoded.tags;
    }
    return result orelse unreachable; // resolveEditTarget guarantees the entry exists
}

// ---------------------------------------------------------------- export

fn runExport(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    // export --for-ai [YYYY-MM-DD[:YYYY-MM-DD]]
    if (rest.len < 1 or rest.len > 2 or !std.mem.eql(u8, rest[0], "--for-ai")) {
        try printUsage(File.stderr(), io);
        return error.Usage;
    }
    var range: ?core.view.DayRange = null;
    if (rest.len == 2) {
        range = parseDayRange(rest[1]) orelse {
            try printUsage(File.stderr(), io);
            return error.Usage;
        };
    }
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const rendered = core.exporter.render(arena, &journal, range) catch |err| switch (err) {
        // Refused before rendering; re-verify only to report the position.
        error.VerifyFailed => {
            const result = try journal.verify(arena);
            try reportIssue(err_file, io, arena, result.issue.?);
            return error.VerifyFailed;
        },
        else => return err,
    };
    try printBlock(out, io, rendered);
}

/// `YYYY-MM-DD` (one day) or `YYYY-MM-DD:YYYY-MM-DD` (inclusive range).
fn parseDayRange(s: []const u8) ?core.view.DayRange {
    const split = std.mem.indexOfScalar(u8, s, ':');
    const start = parseCivilDate(s[0 .. split orelse s.len]) orelse return null;
    if (split) |c| {
        const end = parseCivilDate(s[c + 1 ..]) orelse return null;
        return core.view.DayRange{ .start = start, .end = end + 1 };
    }
    return core.view.DayRange{ .start = start, .end = start + 1 };
}

// ---------------------------------------------------------------- verify

fn runVerify(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
) RunError!void {
    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try journal.verify(arena);
    if (result.ok) {
        const line = if (result.record_count == 0) "ok: journal is empty" else blk: {
            const head_hex = try hexOf(arena, &result.head);
            const redacted = if (result.redacted_count > 0)
                try arena.print(", {d} redacted", .{result.redacted_count})
            else
                "";
            break :blk try arena.print("ok: {d} record(s), head {s}{s}", .{ result.record_count, head_hex, redacted });
        };
        try printLine(out, io, line);

        // The anchor check (anchor-format section 6) runs only on a journal
        // that passed verify; a failing latest anchor means the journal must
        // not be trusted.
        const outcome = try journal.checkAnchors(arena);
        if (outcome.failure) |failure| {
            const file = outcome.file_name orelse "anchor";
            try printLine(err_file, io, try arena.print("FAIL: anchor {s}: {s}", .{ file, anchorFailureReason(failure) }));
            return error.VerifyFailed;
        }
        if (outcome.ok) |check| {
            const head_hex = try hexOf(arena, &check.artifact.head);
            try printLine(out, io, try arena.print("anchor: ok (checkpoint seq {d}, head {s})", .{
                check.artifact.checkpoint_seq,
                head_hex,
            }));
        }

        // The OTS anchor check (spec/ots-anchor.md section 6.1) runs on a
        // journal that passed verify: every stored proof must still bind to
        // its segment's footer head, or the journal must not be trusted.
        const ots_results = try journal.checkOtsAnchors(arena);
        for (ots_results) |check| {
            if (!check.ok) {
                const reason = otsCheckFailureReason(check.failure.?);
                try printLine(err_file, io, try arena.print("FAIL: ots anchors/{s}: {s}", .{ check.file_name, reason }));
                return error.VerifyFailed;
            }
            try printLine(out, io, try arena.print("ots: ok ({s}, {s})", .{
                check.file_name,
                try attestationSummary(arena, check.attestations),
            }));
        }
    } else {
        try reportIssue(err_file, io, arena, result.issue.?);
        return error.VerifyFailed;
    }
}

fn anchorFailureReason(failure: core.journal.Journal.CheckAnchorsFailure) []const u8 {
    return switch (failure) {
        error.CountRegression => "journal is shorter than the anchor (records removed after the checkpoint)",
        error.CheckpointMissing => "anchored checkpoint not found in the journal (truncated or rewritten since the anchor)",
        error.BadLength => "artifact is not 190 bytes (corrupted)",
        error.BadMagic => "artifact has a bad magic (corrupted)",
        error.BadVersion => "artifact has an unknown version",
        error.ReservedNotZero => "artifact has a non-zero reserved byte",
        error.BadHash => "artifact hash mismatch (corrupted)",
        error.NonCanonicalKey => "artifact public key is not a valid Ed25519 point",
        error.SignatureVerificationFailed => "artifact signature verification failed (artifact or key corrupted)",
    };
}

fn otsCheckFailureReason(failure: core.journal.Journal.OtsCheckFailure) []const u8 {
    return switch (failure) {
        error.SegmentMissing => "the referenced segment is missing (the journal was truncated)",
        error.SegmentNotSealed => "the referenced segment is not sealed",
        else => |err| otsFailureReason(err),
    };
}

fn otsFailureReason(err: core.ots.VerifyError) []const u8 {
    return switch (err) {
        error.TooLarge => "proof exceeds the 1 MiB limit",
        error.Truncated => "proof is truncated",
        error.TrailingGarbage => "trailing garbage after the proof tree",
        error.BadMagic => "bad magic (not an OpenTimestamps v1 detached proof)",
        error.BadVersion => "unsupported proof version",
        error.BadHashOp => "unsupported file hash op (expected sha256)",
        error.DigestMismatch => "proof does not commit to this segment's footer head (the segment changed after stamping, or the proof is for another segment)",
        error.UnknownOp => "unknown op in the proof tree",
        error.OpArgEmpty => "empty op argument in the proof",
        error.OpArgTooLong => "op argument exceeds 4096 bytes",
        error.MsgTooLong => "op applied to a message exceeding 4096 bytes",
        error.ResultTooLong => "op result exceeds 4096 bytes",
        error.RecursionLimit => "proof tree deeper than 256",
        error.AttestationPayloadTooLong => "attestation payload exceeds 8192 bytes",
        error.BadAttestation => "malformed attestation payload",
        error.BadUri => "malformed pending attestation URI",
        error.VaruintTooLong => "malformed varint in the proof",
    };
}

/// A short human summary of a proof's attestations, for the stamp/verify
/// output lines.
fn attestationSummary(allocator: Allocator, hits: []const core.ots.AttestationHit) Allocator.Error![]const u8 {
    if (hits.len == 0) return "no attestations";
    var parts = std.ArrayList([]const u8).empty;
    errdefer parts.deinit(allocator);
    for (hits) |hit| {
        switch (hit.attestation) {
            .bitcoin => |h| try parts.append(allocator, try allocator.print("bitcoin height {d}", .{h})),
            .litecoin => |h| try parts.append(allocator, try allocator.print("litecoin height {d}", .{h})),
            .pending => |uri| try parts.append(allocator, try allocator.print("pending calendar {s}", .{uri})),
            .unknown => try parts.append(allocator, "unknown attestation"),
        }
    }
    if (parts.items.len == 1) return try allocator.print("attested at {s}", .{parts.items[0]});
    return try std.mem.join(allocator, ", ", parts.items);
}

/// Reads the proof file at `path` (relative paths resolve against the
/// current directory). A missing file prints a message and becomes
/// TargetNotFound.
const ReadProofError = Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError ||
    std.process.CurrentPathError || error{TargetNotFound};

fn readProofFile(allocator: Allocator, io: Io, err_file: File, path: []const u8) ReadProofError![]u8 {
    const abs = if (std.Io.Dir.path.isAbsolute(path))
        path
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        break :blk try allocator.print("{s}/{s}", .{ cwd, path });
    };
    const d = if (std.fs.path.dirname(abs)) |parent|
        try Dir.openDirAbsolute(io, parent, .{})
    else
        Dir.cwd();
    defer Dir.close(d, io);
    return Dir.readFileAlloc(d, io, std.fs.path.basename(abs), allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            printLine(err_file, io, try allocator.print("no such file: {s}", .{path})) catch return error.InputOutput;
            return error.TargetNotFound;
        },
        else => return err,
    };
}

// ------------------------------------------------------------- ots-stamp

fn runOtsStamp(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    var segment_name: ?[]const u8 = null;
    var proof_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--proof")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            if (proof_path != null) return error.Usage;
            proof_path = rest[i];
        } else if (segment_name != null or std.mem.startsWith(u8, arg, "-")) {
            return error.Usage;
        } else {
            segment_name = arg;
        }
    }
    const seg_name = segment_name orelse return error.Usage;
    const proof_file = proof_path orelse return error.Usage;
    if (!core.journal.isSegmentName(seg_name)) {
        try printLine(err_file, io, try arena.print("no such segment: {s}", .{seg_name}));
        return error.TargetNotFound;
    }

    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);

    const seg_bytes = try journal.readSegment(arena, seg_name);
    const head = core.segment.footerHead(seg_bytes) catch |err| switch (err) {
        error.NotSealed => {
            try printLine(err_file, io, try arena.print("segment {s} is not sealed; only sealed segments can be stamped", .{seg_name}));
            return error.SegmentNotSealed;
        },
        else => |e| return e,
    };
    var expected: [32]u8 = undefined;
    core.records.Sha256.hash(&head, &expected, .{});

    const proof = try readProofFile(arena, io, err_file, proof_file);
    const verification = core.ots.verify(arena, proof, &expected) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try printLine(err_file, io, try arena.print("ots-stamp: proof verification failed: {s}", .{otsFailureReason(e)}));
            return error.BadOtsProof;
        },
    };

    const month = seg_name[0..7];
    try journal.writeOtsAnchorFile(arena, month, proof);
    try printLine(out, io, try arena.print(
        "ots-stamp: ok (anchors/ots-{s}.ots, {s})",
        .{ month, try attestationSummary(arena, verification.attestations) },
    ));
}

// ------------------------------------------------------------- ots-export

fn runOtsExport(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    var segment_name: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= rest.len) return error.Usage;
            if (out_path != null) return error.Usage;
            out_path = rest[i];
        } else if (segment_name != null or std.mem.startsWith(u8, arg, "-")) {
            return error.Usage;
        } else {
            segment_name = arg;
        }
    }
    const seg_name = segment_name orelse return error.Usage;
    if (!core.journal.isSegmentName(seg_name)) {
        try printLine(err_file, io, try arena.print("no such segment: {s}", .{seg_name}));
        return error.TargetNotFound;
    }

    const journal = try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    _ = try verifyOrReport(arena, io, err_file, &journal);

    const seg_bytes = try journal.readSegment(arena, seg_name);
    const head = core.segment.footerHead(seg_bytes) catch |err| switch (err) {
        error.NotSealed => {
            try printLine(err_file, io, try arena.print("segment {s} is not sealed; only sealed segments can be stamped", .{seg_name}));
            return error.SegmentNotSealed;
        },
        else => |e| return e,
    };

    const target = out_path orelse blk: {
        const cwd = try std.process.currentPathAlloc(io, arena);
        break :blk try arena.print("{s}/{s}.head", .{ cwd, seg_name });
    };
    const display = out_path orelse target;
    const d = if (std.fs.path.dirname(target)) |parent|
        try Dir.openDirAbsolute(io, parent, .{})
    else
        Dir.cwd();
    defer Dir.close(d, io);
    const f = Dir.createFile(d, io, std.fs.path.basename(target), .{}) catch |err| switch (err) {
        else => return err,
    };
    defer File.close(f, io);
    try File.writeStreamingAll(f, io, &head);
    try printLine(out, io, try arena.print(
        "ots-export: wrote {s} (head {s}); anchor this file to get an .ots proof",
        .{ display, try hexOf(arena, &head) },
    ));
}

// ---------------------------------------------------------------- mcp

/// `zephyr mcp [--allow-write]` — the read-only MCP server (spec/mcp.md).
/// stdin/stdout are the protocol channel; the journal must exist unless
/// --allow-write is set (then a fresh journal is created).
fn runMcp(
    arena: Allocator,
    io: Io,
    err_file: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) RunError!void {
    var allow_write = false;
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--allow-write")) {
            allow_write = true;
        } else {
            try printUsage(err_file, io);
            return error.Usage;
        }
    }
    const journal = if (allow_write)
        try core.journal.Journal.open(arena, io, environ_map, path, true)
    else
        try openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    var server = mcp.server.Server.init(&journal, allow_write);
    return server.run(arena, io);
}

// ---------------------------------------------------------------- helpers

fn openReadJournal(
    arena: Allocator,
    io: Io,
    err_file: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
) RunError!core.journal.Journal {
    return core.journal.Journal.open(arena, io, environ_map, path, false) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try printLine(err_file, io, try arena.print("journal not found: {s}", .{path}));
            return error.JournalNotFound;
        },
        else => return err,
    };
}

fn verifyOrReport(arena: Allocator, io: Io, err_file: File, journal: *const core.journal.Journal) RunError!core.journal.VerifyResult {
    const result = try journal.verify(arena);
    if (!result.ok) {
        try reportIssue(err_file, io, arena, result.issue.?);
        return error.VerifyFailed;
    }
    return result;
}

fn reportTargetError(arena: Allocator, io: Io, file: File, target: u64, err: core.journal.Journal.ResolveTargetError) RunError!void {
    const msg = switch (err) {
        error.TargetNotFound => try arena.print("no such entry: seq {d}", .{target}),
        error.TargetNotEntry => try arena.print("seq {d} is not an entry", .{target}),
    };
    try printLine(file, io, msg);
}

fn nowMs(io: Io) u64 {
    const ms = Io.Timestamp.now(io, .real).toMilliseconds();
    if (ms < 0) std.debug.panic("wall clock is before the Unix epoch", .{});
    return @intCast(ms);
}

fn parseCivilDate(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u64, s[8..10], 10) catch return null;
    return core.view.dateToCivilDay(year, month, day);
}

const ParsedArgs = struct {
    tags: std.ArrayList([]const u8),
    parts: std.ArrayList([]const u8),

    fn deinit(self: *ParsedArgs, allocator: Allocator) void {
        self.tags.deinit(allocator);
        self.parts.deinit(allocator);
    }
};

const ParseArgsError = Allocator.Error || error{Usage};

/// `-t TAG` / `-tTAG` flags plus free text parts.
fn parseArgs(allocator: Allocator, rest: []const []const u8) ParseArgsError!ParsedArgs {
    var tags = std.ArrayList([]const u8).empty;
    errdefer tags.deinit(allocator);
    var parts = std.ArrayList([]const u8).empty;
    errdefer parts.deinit(allocator);
    var j: usize = 0;
    while (j < rest.len) : (j += 1) {
        const arg = rest[j];
        if (std.mem.eql(u8, arg, "-t")) {
            j += 1;
            if (j >= rest.len) return error.Usage;
            try tags.append(allocator, rest[j]);
        } else if (std.mem.startsWith(u8, arg, "-t") and arg.len > 2) {
            try tags.append(allocator, arg[2..]);
        } else {
            try parts.append(allocator, arg);
        }
    }
    return ParsedArgs{ .tags = tags, .parts = parts };
}

/// Joins parts with a single space (empty for no parts).
fn joinParts(allocator: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    var size: usize = 0;
    for (parts) |p| size += p.len + 1;
    const text = try allocator.alloc(u8, if (parts.len == 0) 0 else size - 1);
    var w: usize = 0;
    for (parts, 0..) |p, k| {
        if (k > 0) {
            text[w] = ' ';
            w += 1;
        }
        @memcpy(text[w .. w + p.len], p);
        w += p.len;
    }
    return text;
}

fn resolveJournalPath(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) core.journal.OpenError![]const u8 {
    const raw = if (explicit) |p| p else blk: {
        if (environ_map.get("ZEPHYR_HOME")) |home| break :blk home;
        if (environ_map.get("HOME")) |home| break :blk try allocator.print("{s}/.local/share/zephyr", .{home});
        return error.JournalNotFound;
    };
    if (std.Io.Dir.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    return try allocator.print("{s}/{s}", .{ cwd, raw });
}

fn reportIssue(file: File, io: Io, allocator: Allocator, issue: core.journal.VerifyIssue) RunError!void {
    const line = try allocator.print("FAIL: {s} seq {d} {s}: {s}", .{ issue.file, issue.seq, issue.field, issue.detail });
    try printLine(file, io, line);
}

fn printLine(file: File, io: Io, text: []const u8) File.Writer.Error!void {
    try File.writeStreamingAll(file, io, text);
    try File.writeStreamingAll(file, io, "\n");
}

/// Writes text that already carries its trailing newline.
fn printBlock(file: File, io: Io, text: []const u8) File.Writer.Error!void {
    try File.writeStreamingAll(file, io, text);
}

fn printUsage(file: File, io: Io) File.Writer.Error!void {
    const usage =
        \\zephyr — local-first, tamper-evident journal
        \\
        \\Usage:
        \\  zephyr "text"                     quick log
        \\  zephyr log [-t TAG]... "text"     log with optional tags
        \\  zephyr today | yesterday | week   entries for today, yesterday,
        \\                                   or the current week (Mon-Sun)
        \\  zephyr on YYYY-MM-DD              entries on a specific date
        \\  zephyr search "query"             keyword search
        \\  zephyr ask [from:to] <question...>
        \\                                   deterministic context pack for
        \\                                   the user's AI: profile, notes,
        \\                                   period digest, keyword matches.
        \\                                   from:to is YYYY-MM-DD[:YYYY-MM-DD]
        \\  zephyr recap [start..end]         period digest (default: the
        \\                                   current week, Mon-Sun)
        \\  zephyr profile                    derived profile plus notes.md
        \\\  zephyr derived status|rebuild     inspect or force-rebuild the
        \\\                                   derived artifacts; `rebuild
        \\\                                   --embeddings` also builds the
        \\\                                   vector artifact (loads the model)
        \\\  zephyr rank <query...> [--mode keyword|vector|hybrid]
        \\\                                   [--top N]  ranked retrieval;
        \\\                                   default: hybrid, top 10. Vector
        \\\                                   and hybrid need the fresh
        \\\                                   embedding artifact
        \\  zephyr edit <seq> [-t TAG]... "text"
        \\                                   amend an entry (tags kept unless
        \\                                   -t is given)
        \\  zephyr rm <seq>                   hide an entry (tombstone)
        \\  zephyr redact <seq> [--yes]       remove an entry's content from the
        \\                                   file (headers and chain are kept)
        \\  zephyr checkpoint [--key PATH]    sign the journal state into an anchor
        \\                                   artifact (anchors/checkpoint-<seq>.zpa)
        \\  zephyr ots-stamp <segment> --proof <path>
        \\                                   attach a standard OpenTimestamps
        \\                                   proof of a sealed segment's footer
        \\                                   head (anchors/ots-<YYYY-MM>.ots)
        \\  zephyr ots-export <segment> [--out <path>]
        \\                                   write the segment's 32-byte footer
        \\                                   head for external OTS tooling
        \\  zephyr verify                     full integrity check (plus the
        \\                                   anchor checks, when anchors exist)
        \\  zephyr export --for-ai [range]   LLM view of the log (refuses a
        \\                                   failing log); range: YYYY-MM-DD or
        \\                                   YYYY-MM-DD:YYYY-MM-DD
        \\  zephyr mcp [--allow-write]      start the read-only MCP (AI) server
        \\                                   on stdio; --allow-write enables
        \\                                   the add_entry tool
        \\
        \\Options:
        \\  --journal PATH    journal directory (default: $ZEPHYR_HOME or
        \\                    ~/.local/share/zephyr)
        \\  --version         print version
        \\  --help            this help
        \\
    ;
    return File.writeStreamingAll(file, io, usage);
}

fn hexOf(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, hash.len * 2);
    for (hash, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}

/// The first six bytes as twelve lowercase hex digits (status lines only;
/// spec/semantic.md section 7).
fn hex12Of(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, 12);
    for (hash[0..6], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}
