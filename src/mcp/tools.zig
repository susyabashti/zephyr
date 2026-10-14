//! MCP tool definitions and handlers (spec/mcp.md section 5).
//!
//! Argument validation (`validate`) is separated from execution (`execute`)
//! so the server can map each failure to the right JSON-RPC class: reject
//! errors become -32602, execution errors become `isError` tool results.
//! Every handler verifies the chain before serving data (section 4).

const std = @import("std");
const core = @import("zephyr_core");
const journal_mod = core.journal;
const view = core.view;
const search = core.search;
const protocol = @import("protocol.zig");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

/// Default cap on search matches per call (spec/mcp.md section 6).
pub const DefaultSearchLimit: u64 = 20;

/// One advertised tool (spec/mcp.md section 5). The strings are static and
/// contain no characters that need JSON escaping.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

// `add_entry` is the last entry: the read-only tool list is the prefix.
const tools_all = [_]Tool{
    .{
        .name = "get_entries",
        .description = "Journal entries between two dates, rendered as the LLM view. " ++
            "Dates are YYYY-MM-DD; to is inclusive and defaults to from. Private and " ++
            "tombstoned entries are excluded; redacted entries appear as a [redacted] marker.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"from\":{\"type\":\"string\",\"description\":\"Start date, YYYY-MM-DD.\"}," ++
            "\"to\":{\"type\":\"string\",\"description\":\"End date, YYYY-MM-DD, inclusive (optional).\"}},\"required\":[\"from\"]}",
    },
    .{
        .name = "search",
        .description = "Case-insensitive substring search over the entry text the LLM view " ++
            "shows. Returns matches in view order; private and redacted content never matches.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Substring to search for.\"}," ++
            "\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of matches (default 20, minimum 1).\"}},\"required\":[\"query\"]}",
    },
    .{
        .name = "get_digest",
        .description = "The LLM view of the current week (Mon-Sun) or the current month, in " ++
            "the journal timezone. Use this before drilling into raw entries.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"period\":{\"type\":\"string\",\"description\":\"week or month.\"}},\"required\":[\"period\"]}",
    },
    .{
        .name = "get_profile",
        .description = "The user-maintained profile document at journal/profile.md, with the " ++
            "provenance line. Reports a missing profile instead of failing.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
    },
    .{
        .name = "verify_status",
        .description = "Chain integrity of the journal: ok with record count, redaction count, " ++
            "and head hash, or the exact failure (file, seq, field, detail).",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
    },
    .{
        .name = "get_context",
        .description = "Deterministic context pack for answering a question from the journal: " ++
            "provenance, the question verbatim, the derived profile, the user's notes, the " ++
            "period digest, keyword matches, and an instruction to answer only from the pack. " ++
            "from/to are optional YYYY-MM-DD dates bounding the period (a single date covers " ++
            "that day; no dates: a YYYY-MM-DD in the question, else the current week).",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"The question to answer from the journal.\"},\"from\":{\"type\":\"string\",\"description\":\"Period start date, YYYY-MM-DD (optional).\"},\"to\":{\"type\":\"string\",\"description\":\"Period end date, YYYY-MM-DD, inclusive (optional).\"}},\"required\":[\"question\"]}",
    },
    .{
        .name = "add_entry",
        .description = "Append a new entry to the journal with the current time. " ++
            "Only advertised when the server was started with --allow-write.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"Entry text.\"}," ++
            "\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Optional tags.\"}},\"required\":[\"text\"]}",
    },
};

pub fn list(allow_write: bool) []const Tool {
    comptime std.debug.assert(std.mem.eql(u8, tools_all[6].name, "add_entry"));
    return tools_all[0..(if (allow_write) tools_all.len else 6)];
}

/// The payload of a validated add_entry call.
pub const AddEntry = struct {
    text: []const u8,
    tags: []const []const u8,
};

/// A validated, normalized tool call. Slices borrow from the per-message
/// arena passed to `validate`.
pub const ToolCall = union(enum) {
    get_entries: struct {
        from_day: i64,
        end_day: i64, // exclusive
    },
    search: struct {
        query: []const u8,
        limit: u64,
    },
    get_digest: struct {
        range: view.DayRange,
    },
    get_profile: struct {},
    verify_status: struct {},
    get_context: struct {
        question: []const u8,
        /// Null when the call carried no from/to: the period falls back to
        /// a YYYY-MM-DD in the question, else the current week.
        range: ?view.DayRange,
    },
    add_entry: AddEntry,
};

const NoArgs = struct {};
const GetEntriesArgs = struct {
    from: []const u8,
    to: ?[]const u8 = null,
};
const SearchArgs = struct {
    query: []const u8,
    limit: ?i64 = null,
};
const DigestArgs = struct {
    period: []const u8,
};
const GetContextArgs = struct {
    question: []const u8,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
};
const AddEntryArgs = struct {
    text: []const u8,
    tags: ?[]const []const u8 = null,
};

/// Failures of `validate`: the request is rejected with JSON-RPC -32602.
pub const RejectError = std.json.ParseFromValueError || error{
    ParamsNotObject,
    UnknownTool,
    WriteDisabled,
    EmptyText,
    EmptyQuery,
    EmptyQuestion,
    BadDate,
    InvertedRange,
    BadPeriod,
    BadLimit,
};

/// Validates and normalizes the arguments of `name`. `today_day` (civil day,
/// days since the Unix epoch) feeds `get_digest`; the server computes it.
pub fn validate(
    allocator: Allocator,
    allow_write: bool,
    name: []const u8,
    params: ?protocol.Value,
    today_day: i64,
) RejectError!ToolCall {
    if (std.mem.eql(u8, name, "get_entries")) {
        const args = try parseArgs(GetEntriesArgs, allocator, params);
        const from_day = parseDate(args.from) orelse return error.BadDate;
        // to is inclusive; end_day is exclusive.
        const to_day = if (args.to) |to| parseDate(to) orelse return error.BadDate else from_day;
        if (from_day > to_day) return error.InvertedRange;
        return .{ .get_entries = .{ .from_day = from_day, .end_day = to_day + 1 } };
    }
    if (std.mem.eql(u8, name, "search")) {
        const args = try parseArgs(SearchArgs, allocator, params);
        if (args.query.len == 0) return error.EmptyQuery;
        const limit = args.limit orelse DefaultSearchLimit;
        if (limit < 1) return error.BadLimit;
        return .{ .search = .{ .query = args.query, .limit = @as(u64, @intCast(limit)) } };
    }
    if (std.mem.eql(u8, name, "get_digest")) {
        const args = try parseArgs(DigestArgs, allocator, params);
        const range = digestRange(args.period, today_day) orelse return error.BadPeriod;
        return .{ .get_digest = .{ .range = range } };
    }
    if (std.mem.eql(u8, name, "get_profile")) {
        _ = try parseArgs(NoArgs, allocator, params);
        return .get_profile;
    }
    if (std.mem.eql(u8, name, "verify_status")) {
        _ = try parseArgs(NoArgs, allocator, params);
        return .verify_status;
    }
    if (std.mem.eql(u8, name, "get_context")) {
        const args = try parseArgs(GetContextArgs, allocator, params);
        if (args.question.len == 0) return error.EmptyQuestion;
        var range: ?view.DayRange = null;
        if (args.from) |from| {
            const start = parseDate(from) orelse return error.BadDate;
            // to is inclusive; range.end is exclusive. A bare from covers
            // that day; a bare to (no from) likewise.
            const end = if (args.to) |to|
                parseDate(to) orelse return error.BadDate
            else
                start;
            if (start > end) return error.InvertedRange;
            range = view.DayRange{ .start = start, .end = end + 1 };
        } else if (args.to) |to| {
            const day = parseDate(to) orelse return error.BadDate;
            range = view.DayRange{ .start = day, .end = day + 1 };
        }
        return .{ .get_context = .{ .question = args.question, .range = range } };
    }
    if (std.mem.eql(u8, name, "add_entry")) {
        if (!allow_write) return error.WriteDisabled;
        const args = try parseArgs(AddEntryArgs, allocator, params);
        if (args.text.len == 0) return error.EmptyText;
        return .{ .add_entry = .{ .text = args.text, .tags = args.tags orelse &.{} } };
    }
    return error.UnknownTool;
}

/// The current week (Mon-Sun) or calendar month containing `today_day`, as
/// civil days since the Unix epoch (spec/mcp.md section 5).
pub fn digestRange(period: []const u8, today_day: i64) ?view.DayRange {
    if (std.mem.eql(u8, period, "week")) {
        const start = view.weekStart(today_day);
        return .{ .start = start, .end = start + 7 };
    }
    if (std.mem.eql(u8, period, "month")) {
        const date = view.civilDate(today_day) catch return null;
        const year: i64 = date.year;
        const start = view.dateToCivilDay(year, date.month, 1) orelse return null;
        const next = if (date.month == 12)
            view.dateToCivilDay(year + 1, 1, 1)
        else
            view.dateToCivilDay(year, date.month + 1, 1);
        const end = next orelse return null;
        return .{ .start = start, .end = end };
    }
    return null;
}

/// The text of a tool result; `is_error` is true when execution failed
/// (spec/mcp.md section 4). `text` borrows from the per-message arena.
pub const Outcome = struct {
    text: []const u8,
    is_error: bool,
};

/// Failures of `execute`: reported as an `isError` tool result.
pub const CallError = Allocator.Error || journal_mod.Journal.VerifyError || journal_mod.Journal.AppendError ||
    view.RenderError || core.timezone.LoadError || core.dstore.PackError || core.dstore.ResolveRangeError || error{
    VerifyFailed,
    ClockBeforeEpoch,
};

/// Runs a validated tool call against the journal.
pub fn execute(arena: Allocator, io: Io, journal: *const journal_mod.Journal, call: ToolCall) CallError!Outcome {
    return switch (call) {
        .get_entries => |args| entriesInRange(arena, journal, .{ .start = args.from_day, .end = args.end_day }),
        .get_digest => |args| entriesInRange(arena, journal, args.range),
        .search => |args| searchText(arena, journal, args.query, args.limit),
        .get_profile => getProfile(arena, journal),
        .verify_status => verifyStatus(arena, journal),
        .get_context => |args| getContext(arena, io, journal, args.question, args.range),
        .add_entry => |args| addEntry(arena, io, journal, args),
    };
}

// ---------------------------------------------------------------- internals

const Verified = struct {
    result: journal_mod.VerifyResult,
    recs: ?journal_mod.Journal.RecordSet,
};

/// Verify-before-trust (spec/mcp.md section 4): the chain is always checked
/// before any data is read or written.
fn verified(arena: Allocator, journal: *const journal_mod.Journal) CallError!Verified {
    const result = try journal.verify(arena);
    if (!result.ok) return .{ .result = result, .recs = null };
    const recs = try journal.collectRecords(arena);
    return .{ .result = result, .recs = recs };
}

fn entriesInRange(arena: Allocator, journal: *const journal_mod.Journal, range: view.DayRange) CallError!Outcome {
    const v = try verified(arena, journal);
    const recs = v.recs orelse return Outcome{ .text = try refuseText(arena, v.result), .is_error = true };
    defer recs.deinit();
    const rendered = try view.renderRange(arena, recs.headers, recs.payloads, range);
    if (rendered.len > 0) return Outcome{ .text = rendered, .is_error = false };
    // A verified journal with no entries in range still carries its
    // provenance line (spec/mcp.md section 3).
    return Outcome{ .text = try provenanceLine(arena, v.result), .is_error = false };
}

fn searchText(arena: Allocator, journal: *const journal_mod.Journal, query: []const u8, limit: u64) CallError!Outcome {
    const v = try verified(arena, journal);
    const recs = v.recs orelse return Outcome{ .text = try refuseText(arena, v.result), .is_error = true };
    defer recs.deinit();
    const visible = try view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    const matches = try search.find(arena, &visible, query);
    const shown = matches[0..@min(limit, matches.len)];
    const truncated = matches.len > shown.len;
    const rendered = try search.render(arena, shown, query);
    const note = if (truncated)
        try arena.print("\n({d} more match(es) not shown; raise limit or narrow the query)", .{matches.len - shown.len})
    else
        "";
    const text = try arena.print("{s}{s}{s}", .{
        try provenanceLine(arena, v.result), rendered, note,
    });
    return Outcome{ .text = text, .is_error = false };
}

fn getProfile(arena: Allocator, journal: *const journal_mod.Journal) CallError!Outcome {
    const v = try verified(arena, journal);
    if (v.recs == null) return Outcome{ .text = try refuseText(arena, v.result), .is_error = true };
    const prov = try provenanceLine(arena, v.result);
    // The user's notes under a heading, so the AI can tell machine fact
    // from user voice (spec/derived.md sections 6 and 7).
    const notes_section = blk: {
        const notes = journal.readJournalFile(arena, "notes.md") catch |err| switch (err) {
            error.FileNotFound => break :blk try arena.print("# notes\n(no notes)\n", .{}),
            else => |e| return e,
        };
        const newline = if (notes.len > 0 and notes[notes.len - 1] != '\n') "\n" else "";
        break :blk try arena.print("# notes\n{s}{s}", .{ notes, newline });
    };
    const doc = journal.readJournalFile(arena, "profile.md") catch |err| switch (err) {
        error.FileNotFound => return Outcome{
            .text = try arena.print("{s}no profile document at profile.md\n{s}", .{ prov, notes_section }),
            .is_error = false,
        },
        else => |e| return e,
    };
    const newline = if (doc.len > 0 and doc[doc.len - 1] != '\n') "\n" else "";
    const text = try arena.print("{s}{s}{s}{s}", .{ prov, doc, newline, notes_section });
    return Outcome{ .text = text, .is_error = false };
}

fn getContext(arena: Allocator, io: Io, journal: *const journal_mod.Journal, question: []const u8, range: ?view.DayRange) CallError!Outcome {
    const v = try verified(arena, journal);
    const recs = v.recs orelse return Outcome{ .text = try refuseText(arena, v.result), .is_error = true };
    defer recs.deinit();
    const visible = try view.visibleEntries(arena, recs.headers, recs.payloads);
    defer visible.deinit();
    // The server is read-only: the pack is computed in memory (persist =
    // false); the CLI's ask/derived commands are the persisting surface.
    // Hybrid retrieval is unavailable here: the server never loads a model
    // (spec/semantic.md section 6), so retrieval stays keyword-only.
    const pack_range = try core.dstore.resolveRange(io, journal, range, question);
    const pack = try core.dstore.contextPack(arena, journal, &visible, v.result, question, pack_range, false, null);
    return Outcome{ .text = pack, .is_error = false };
}

fn verifyStatus(arena: Allocator, journal: *const journal_mod.Journal) CallError!Outcome {
    const result = try journal.verify(arena);
    if (!result.ok) {
        const issue = result.issue orelse std.debug.panic("verify failed without an issue", .{});
        const text = try arena.print("FAIL: {s} seq {d} {s}: {s}", .{
            issue.file, issue.seq, issue.field, issue.detail,
        });
        return Outcome{ .text = text, .is_error = true };
    }
    const redacted = if (result.redacted_count > 0)
        try arena.print(", {d} redacted", .{result.redacted_count})
    else
        "";
    const text = try arena.print("{s}ok: {d} record(s), head {s}{s}\n", .{
        try provenanceLine(arena, result),
        result.record_count,
        try hexOf(arena, &result.head),
        redacted,
    });
    return Outcome{ .text = text, .is_error = false };
}

fn addEntry(arena: Allocator, io: Io, journal: *const journal_mod.Journal, args: AddEntry) CallError!Outcome {
    const pre = try journal.verify(arena);
    if (!pre.ok) return Outcome{ .text = try refuseText(arena, pre), .is_error = true };
    const now_ms: i64 = Io.Timestamp.now(io, .real).toMilliseconds();
    if (now_ms < 0) return error.ClockBeforeEpoch;
    const ts: u64 = @intCast(now_ms);
    const tz_offset_min = try journal.tzOffsetMinutesAtMs(ts);
    const seq = try journal.appendRecord(arena, .entry, 0, args.text, args.tags, ts, tz_offset_min, false);
    const after = try journal.verify(arena);
    if (!after.ok) {
        return Outcome{
            .text = try arena.print("logged seq {d}\npost-write verify failed: run `zephyr verify`", .{seq}),
            .is_error = true,
        };
    }
    const text = try arena.print("logged seq {d}\n{s}", .{ seq, try provenanceLine(arena, after) });
    return Outcome{ .text = text, .is_error = false };
}

fn parseArgs(comptime T: type, allocator: Allocator, params: ?protocol.Value) RejectError!T {
    if (params) |p| {
        if (p != .object) return error.ParamsNotObject;
        return std.json.parseFromValueLeaky(T, allocator, p, .{ .ignore_unknown_fields = true });
    }
    return std.json.parseFromValueLeaky(T, allocator, protocol.Value{ .object = .empty }, .{ .ignore_unknown_fields = true });
}

/// YYYY-MM-DD to a civil day; null when the shape or the calendar date is
/// invalid (spec/mcp.md section 5).
fn parseDate(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u64, s[8..10], 10) catch return null;
    return view.dateToCivilDay(year, month, day);
}

fn refuseText(arena: Allocator, result: journal_mod.VerifyResult) Allocator.Error![]const u8 {
    const issue = result.issue orelse std.debug.panic("verify failed without an issue", .{});
    return arena.print(
        "journal failed verify: FAIL: {s} seq {d} {s}: {s}\n" ++
            "data refused; the chain is invalid, run `zephyr verify` for details",
        .{ issue.file, issue.seq, issue.field, issue.detail },
    );
}

/// The LLM-view provenance line (spec/mcp.md section 3): `# zephyr:
/// seq 0..N head=<64-hex>`, with N the last seq (0 for an empty journal).
fn provenanceLine(arena: Allocator, result: journal_mod.VerifyResult) Allocator.Error![]const u8 {
    const last_seq: u64 = if (result.record_count == 0) 0 else result.record_count - 1;
    return arena.print("# zephyr: seq 0..{d} head={s}\n", .{ last_seq, try hexOf(arena, &result.head) });
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

test "digestRange: week, month, and December rollover" {
    // 2026-01-15 is a Thursday (civil day 20454).
    const jan15: i64 = view.dateToCivilDay(2026, 1, 15).?;
    const jan12 = view.weekStart(jan15);
    try std.testing.expectEqual(view.weekStart(jan15), jan12);
    const week = digestRange("week", jan15).?;
    try std.testing.expectEqual(jan12, week.start);
    try std.testing.expectEqual(jan12 + 7, week.end);

    const month = digestRange("month", jan15).?;
    try std.testing.expectEqual(view.dateToCivilDay(2026, 1, 1).?, month.start);
    try std.testing.expectEqual(view.dateToCivilDay(2026, 2, 1).?, month.end);

    // December rolls into the next year.
    const dec20 = view.dateToCivilDay(2026, 12, 20).?;
    const dec = digestRange("month", dec20).?;
    try std.testing.expectEqual(view.dateToCivilDay(2026, 12, 1).?, dec.start);
    try std.testing.expectEqual(view.dateToCivilDay(2027, 1, 1).?, dec.end);

    try std.testing.expect(digestRange("year", jan15) == null);
}

test "validate: argument checks and tool gating" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const jan15 = view.dateToCivilDay(2026, 1, 15).?;

    const entries = try validate(allocator, false, "get_entries", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"from\":\"2026-01-15\"}", .{}), jan15);
    try std.testing.expectEqual(jan15, entries.get_entries.from_day);
    try std.testing.expectEqual(jan15 + 1, entries.get_entries.end_day);

    try std.testing.expectError(error.InvertedRange, validate(allocator, false, "get_entries", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"from\":\"2026-01-16\",\"to\":\"2026-01-15\"}", .{}), jan15));

    try std.testing.expectError(error.BadDate, validate(allocator, false, "get_entries", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"from\":\"2026-13-01\"}", .{}), jan15));

    try std.testing.expectError(error.EmptyQuery, validate(allocator, false, "search", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"query\":\"\"}", .{}), jan15));

    try std.testing.expectError(error.BadLimit, validate(allocator, false, "search", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"query\":\"x\",\"limit\":0}", .{}), jan15));

    try std.testing.expectError(error.BadPeriod, validate(allocator, false, "get_digest", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"period\":\"year\"}", .{}), jan15));

    try std.testing.expectError(error.UnknownTool, validate(allocator, false, "drop_table", null, jan15));

    // Write gating: the AI cannot enable add_entry from a request.
    try std.testing.expectError(error.WriteDisabled, validate(allocator, false, "add_entry", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"text\":\"hi\"}", .{}), jan15));

    const added = try validate(allocator, true, "add_entry", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"text\":\"hi\",\"tags\":[\"a\",\"b\"]}", .{}), jan15);
    try std.testing.expectEqualStrings("hi", added.add_entry.text);
    try std.testing.expectEqual(@as(usize, 2), added.add_entry.tags.len);

    try std.testing.expectError(error.EmptyText, validate(allocator, true, "add_entry", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"text\":\"\"}", .{}), jan15));

    // No-arg tools accept absent params; unknown extra args are ignored.
    _ = try validate(allocator, false, "verify_status", null, jan15);
    _ = try validate(allocator, false, "get_profile", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"bogus\":1}", .{}), jan15);

    // get_context: question required; period bounds validated like get_entries.
    try std.testing.expectError(error.EmptyQuestion, validate(allocator, false, "get_context", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"question\":\"\"}", .{}), jan15));
    try std.testing.expectError(error.BadDate, validate(allocator, false, "get_context", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"question\":\"q\",\"from\":\"2026-13-01\"}", .{}), jan15));
    try std.testing.expectError(error.InvertedRange, validate(allocator, false, "get_context", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"question\":\"q\",\"from\":\"2026-01-16\",\"to\":\"2026-01-15\"}", .{}), jan15));
    const ctx = try validate(allocator, false, "get_context", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"question\":\"what\"}", .{}), jan15);
    try std.testing.expectEqual(@as(?view.DayRange, null), ctx.get_context.range);
    const ctx_range = try validate(allocator, false, "get_context", std.json.parseFromSliceLeaky(protocol.Value, allocator, "{\"question\":\"what\",\"from\":\"2026-01-15\",\"to\":\"2026-01-16\"}", .{}), jan15);
    try std.testing.expectEqual(jan15, ctx_range.get_context.range.?.start);
    try std.testing.expectEqual(jan15 + 2, ctx_range.get_context.range.?.end);
}
