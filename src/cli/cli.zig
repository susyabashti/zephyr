//! CLI: zephyr <text>  |  zephyr log [-t TAG]... <text>  |  zephyr verify
//!     zephyr today | yesterday | week | on YYYY-MM-DD  |  zephyr search <q>
//!     zephyr edit <seq> [-t TAG]... <text>  |  zephyr rm <seq>
//!     zephyr redact <seq> [--yes]  |  zephyr checkpoint [--key PATH]
//!     zephyr export --for-ai [YYYY-MM-DD[:YYYY-MM-DD]]
//!
//! Exit codes: 0 ok, 1 integrity or journal error, 2 usage error.

const std = @import("std");
const core = @import("zephyr_core");

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
} || core.anchor.SignError || core.journal.OpenError || core.journal.Journal.AppendError ||
    core.journal.Journal.VerifyError || core.journal.Journal.RedactError ||
    core.journal.Journal.CheckAnchorsError || core.journal.Journal.WriteAnchorError ||
    core.view.RenderError || File.OpenError || File.Writer.Error || std.Io.Reader.ShortError ||
    std.crypto.errors.IdentityElementError;

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
        } else if (std.mem.eql(u8, command, "edit")) {
            try runEdit(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "rm")) {
            try runRm(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "redact")) {
            try runRedact(arena, io, err_file, out, init.environ_map, path, rest);
        } else if (std.mem.eql(u8, command, "checkpoint")) {
            try runCheckpoint(arena, io, err_file, out, init.environ_map, path, rest);
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
        std.mem.eql(u8, s, "search") or std.mem.eql(u8, s, "edit") or
        std.mem.eql(u8, s, "rm") or std.mem.eql(u8, s, "redact") or
        std.mem.eql(u8, s, "checkpoint") or std.mem.eql(u8, s, "export");
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
        \\Proceed? [y/N] 
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
        \\  zephyr edit <seq> [-t TAG]... "text"
        \\                                   amend an entry (tags kept unless
        \\                                   -t is given)
        \\  zephyr rm <seq>                   hide an entry (tombstone)
        \\  zephyr redact <seq> [--yes]       remove an entry's content from the
        \\                                   file (headers and chain are kept)
        \\  zephyr checkpoint [--key PATH]    sign the journal state into an anchor
        \\                                   artifact (anchors/checkpoint-<seq>.zpa)
        \\  zephyr verify                     full integrity check (plus the
        \\                                   anchor check, when anchors exist)
        \\  zephyr export --for-ai [range]   LLM view of the log (refuses a
        \\                                   failing log); range: YYYY-MM-DD or
        \\                                   YYYY-MM-DD:YYYY-MM-DD
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
