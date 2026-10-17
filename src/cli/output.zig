//! All CLI formatting and rendering: the stdout/stderr writers, the usage
//! text, hex rendering, and the FAIL/status/anchor lines the commands
//! print.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("errors.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

/// Terminal styling for human-facing lines: the same line, with SGR color
/// codes only when the stream is a TTY and $NO_COLOR is not set
/// (no-color.org). Piped output stays byte-stable, so scripts and the
/// byte-exact gates are unaffected.
pub const Style = struct {
    enabled: bool,

    /// Styling off: plain text only.
    pub const off: @This() = .{ .enabled = false };

    /// Detect once at startup, on the stream the user reads: color only on
    /// a TTY, and only when $NO_COLOR is unset or empty.
    pub fn detect(file: File, io: Io, environ_map: *const std.process.Environ.Map) Style {
        const is_tty = File.isTty(file, io) catch false;
        if (!is_tty) return .off;
        const no_color = environ_map.get("NO_COLOR") orelse return .{ .enabled = true };
        if (no_color.len == 0) return .{ .enabled = true };
        return .off;
    }

    /// Wrap `text` in an SGR code and a reset. When styling is off the
    /// text is returned as-is (literals and arena slices both work).
    pub fn wrap(
        self: Style,
        allocator: Allocator,
        comptime code: []const u8,
        text: []const u8,
    ) Allocator.Error![]const u8 {
        if (!self.enabled) return text;
        return allocator.print("\x1b[{s}m{s}\x1b[0m", .{ code, text });
    }

    /// The `✓ ` prefix of a success line (green).
    pub fn okMark(self: Style, allocator: Allocator) Allocator.Error![]const u8 {
        return self.wrap(allocator, "32", "✓ ");
    }

    /// The `✗ ` prefix of a failure line (red).
    pub fn errMark(self: Style, allocator: Allocator) Allocator.Error![]const u8 {
        return self.wrap(allocator, "31", "✗ ");
    }

    /// Secondary detail — paths, hashes, hints (dim).
    pub fn dim(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "2", text);
    }

    /// The primary number of a line, a seq (cyan).
    pub fn accent(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "36", text);
    }

    /// The section title of a view — a day header's date (bold).
    pub fn bold(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "1", text);
    }

    /// A section title of a derived surface (blue, bold).
    pub fn title(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "1;34", text);
    }

    /// A frequency table's bar (soft green — a quiet level meter).
    pub fn bar(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "2;32", text);
    }

    /// Verdicts: fresh (green), stale (yellow), corrupt (red).
    pub fn good(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "32", text);
    }

    pub fn warn(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "33", text);
    }

    pub fn bad(self: Style, allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        return self.wrap(allocator, "31", text);
    }
};

/// The singular or plural form of a count noun ("record" / "records").
pub fn countNoun(count: u64, comptime singular: []const u8, comptime plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
}

pub fn printLine(file: File, io: Io, text: []const u8) File.Writer.Error!void {
    try File.writeStreamingAll(file, io, text);
    try File.writeStreamingAll(file, io, "\n");
}

/// Writes text that already carries its trailing newline.
pub fn printBlock(file: File, io: Io, text: []const u8) File.Writer.Error!void {
    try File.writeStreamingAll(file, io, text);
}

pub fn printUsage(file: File, io: Io) File.Writer.Error!void {
    const usage =
        \\zephyr — local-first, tamper-evident journal
        \\
        \\Usage:
        \\  zephyr                          open the editor to log a new
        \\                                   entry
        \\  zephyr "text"                   quick log
        \\  zephyr log [-t TAG]... "text"   log with optional tags; with no
        \\                                   text (on a TTY) the editor is
        \\                                   opened instead
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
        \\  zephyr derived status|rebuild     inspect or force-rebuild the
        \\                                   derived artifacts; `rebuild
        \\                                   --embeddings` also builds the
        \\                                   vector artifact (loads the model)
        \\  zephyr rank <query...> [--mode keyword|vector|hybrid]
        \\                                   [--top N]  ranked retrieval;
        \\                                   default: hybrid, top 10. Vector
        \\                                   and hybrid need the fresh
        \\                                   embedding artifact
        \\  zephyr model fetch [--force]     download the pinned embedding
        \\                                   model (auto-downloaded on first
        \\                                   use of the embedding surface)
        \\  zephyr model status             where the model lives, and
        \\                                   whether it matches the pin
        \\  zephyr key status               where the journal's master key
        \\                                   lives (the store pinned in the
        \\                                   journal's meta file)
        \\  zephyr edit <seq> [-t TAG]... "text"
        \\                                   amend an entry (tags kept unless
        \\                                   -t is given); with only a seq
        \\                                   (on a TTY) the editor is opened,
        \\                                   seeded with the current text
        \\                                   and tags
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
        \\\  zephyr verify [--head]            full integrity check (plus the
        \\\                                   anchor checks, when anchors
        \\\                                   exist); --head prints the head hash
        \\  zephyr export --for-ai [range]   LLM view of the log (refuses a
        \\                                   failing log); range: YYYY-MM-DD or
        \\                                   YYYY-MM-DD:YYYY-MM-DD
        \\  zephyr mcp [--allow-write]      start the read-only MCP (AI) server
        \\                                   on stdio; --allow-write enables
        \\                                   the add_entry tool
        \\
        \\In the editor, the first line `# tags: a, b` holds the entry's tags
        \\ (comma-separated; an empty or absent line means no tags); the
        \\ remaining lines are the text, joined into one. Saving with an
        \\ empty text — or without any change, when amending — cancels.
        \\
        \\.Options:
        \\  --journal PATH    journal directory (default: $ZEPHYR_HOME or
        \\                    ~/.local/share/zephyr)
        \\  --no-pager        print long output directly, without a pager
        \\  --version         print version
        \\  --help            this help
        \\
    ;
    return File.writeStreamingAll(file, io, usage);
}

/// The day rule of a styled day view: `== ` + the blue title date + a dim
/// weekday, an optional dim ` (today)` marker, and a dim `=` fill padding
/// the line to `width` display columns (no fill when the styled head
/// reaches `width`). Intermediates leak to the caller's arena, like the
/// other styled renderers.
pub fn dayRule(
    allocator: Allocator,
    style: Style,
    date_str: []const u8,
    weekday: []const u8,
    is_today: bool,
    width: usize,
) Allocator.Error![]const u8 {
    const head_len = 3 + date_str.len + 1 + weekday.len + (if (is_today) " (today)".len else 0);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "== ");
    try out.appendSlice(allocator, try style.title(allocator, date_str));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, try style.dim(allocator, weekday));
    if (is_today) try out.appendSlice(allocator, try style.dim(allocator, " (today)"));
    if (width > head_len) {
        const fill = try allocator.alloc(u8, width - head_len);
        @memset(fill, '=');
        try out.appendSlice(allocator, try style.dim(allocator, fill));
    }
    return out.toOwnedSlice(allocator);
}

/// Wrap `text` to `width` display columns: greedy word wrap on ASCII
/// spaces (runs collapse; a trailing run drops), with continuation lines
/// indented to `indent` — the column the text's first line starts in. A
/// word longer than the available width hard-splits. Display width is the
/// code point count: exact for Latin and Hebrew, an approximation for
/// wide (e.g. CJK) characters. When `width <= indent` or `text` is empty,
/// `text` is returned as-is. The returned slice is owned by `allocator`
/// unless it is the input as-is — the caller must never free it (it is
/// either an arena leak or the caller's own text).
pub fn wrapText(allocator: Allocator, text: []const u8, width: usize, indent: usize) Allocator.Error![]const u8 {
    if (width <= indent or text.len == 0) return text;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first_segment = true;
    while (it.next()) |segment| {
        if (!first_segment) try out.append(allocator, '\n');
        first_segment = false;
        try wrapLine(allocator, &out, segment, width - indent, indent);
    }
    return out.toOwnedSlice(allocator);
}

/// Append `line` to `out`, wrapped to `avail` display columns with the
/// continuation indent of `indent` columns.
fn wrapLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8, avail: usize, indent: usize) Allocator.Error!void {
    var state = wrapLineState{};
    var it = std.unicode.Wtf8View.initUnchecked(line).iterator();
    while (it.peekCodepoint()) |cp| {
        if (cp == ' ') {
            _ = it.nextCodepointSlice() orelse unreachable; // peekCodepoint saw it
            continue; // spaces collapse; a trailing run drops
        }
        const rest = it.peek(std.math.maxInt(usize));
        const word = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
        try emitWord(allocator, out, word, avail, indent, &state);
        // Step past the word (the separator space is the loop's job).
        var k = wtf8CodepointCount(word);
        while (k > 0) : (k -= 1) _ = it.nextCodepointSlice() orelse unreachable; // peekCodepoint saw the word
    }
}

/// Append `word` to the line: a space separator when the line is not
/// empty and the word fits on it, otherwise a wrap first; a word longer
/// than the available width hard-splits across lines.
fn emitWord(allocator: Allocator, out: *std.ArrayList(u8), word: []const u8, avail: usize, indent: usize, state: *wrapLineState) Allocator.Error!void {
    const wc = wtf8CodepointCount(word);
    if (!state.empty and state.used + 1 + wc > avail) {
        try wrapTo(allocator, out, indent);
        state.used = 0;
    } else if (!state.empty) {
        try out.append(allocator, ' ');
        state.used += 1;
    }
    state.empty = false;
    var w = std.unicode.Wtf8View.initUnchecked(word).iterator();
    var remaining = word;
    while (remaining.len > 0) {
        const room = avail - state.used;
        if (room < 1) {
            try wrapTo(allocator, out, indent);
            state.used = 0;
            continue; // recompute the room on the fresh line
        }
        const chunk = w.peek(room);
        const n = wtf8CodepointCount(chunk);
        try out.appendSlice(allocator, chunk);
        state.used += n;
        remaining = remaining[chunk.len..];
        var k = n;
        while (k > 0) : (k -= 1) _ = w.nextCodepointSlice() orelse unreachable; // peek saw the chunk
        if (remaining.len > 0) {
            try wrapTo(allocator, out, indent);
            state.used = 0;
        }
    }
}

/// A wrap: a newline and `indent` spaces.
fn wrapTo(allocator: Allocator, out: *std.ArrayList(u8), indent: usize) Allocator.Error!void {
    try out.append(allocator, '\n');
    for (0..indent) |_| try out.append(allocator, ' ');
}

/// The current line's state while wrapping: the display columns used so
/// far, and whether the line has any content yet.
const wrapLineState = struct {
    used: usize = 0,
    empty: bool = true,
};

/// The code point count of `s`, trusted to be valid WTF-8 (journal text
/// is; the frozen text rules forbid control bytes).
fn wtf8CodepointCount(s: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Wtf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |_| n += 1;
    return n;
}

/// The first six bytes as twelve lowercase hex digits (status lines only;
/// spec/semantic.md section 7).
pub fn hex12Of(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, 12);
    for (hash[0..6], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}

pub fn reportIssue(
    file: File,
    io: Io,
    style: Style,
    allocator: Allocator,
    issue: core.journal.VerifyIssue,
) errors.RunError!void {
    const mark = try style.errMark(allocator);
    const line = try allocator.print("{s}{s} seq {d} {s}: {s}", .{ mark, issue.file, issue.seq, issue.field, issue.detail });
    try printLine(file, io, line);
}

pub fn reportTargetError(
    arena: Allocator,
    io: Io,
    style: Style,
    file: File,
    target: u64,
    err: core.journal.Journal.ResolveTargetError,
) errors.RunError!void {
    const mark = try style.errMark(arena);
    const msg = switch (err) {
        error.TargetNotFound => try arena.print("{s}no such entry: seq {d}", .{ mark, target }),
        error.TargetNotEntry => try arena.print("{s}seq {d} is not an entry", .{ mark, target }),
    };
    try printLine(file, io, msg);
}

pub fn anchorFailureReason(failure: core.journal.Journal.CheckAnchorsFailure) []const u8 {
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

pub fn otsCheckFailureReason(failure: core.journal.Journal.OtsCheckFailure) []const u8 {
    return switch (failure) {
        error.SegmentMissing => "the referenced segment is missing (the journal was truncated)",
        error.SegmentNotSealed => "the referenced segment is not sealed",
        else => |err| otsFailureReason(err),
    };
}

pub fn otsFailureReason(err: core.ots.VerifyError) []const u8 {
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
pub fn attestationSummary(allocator: Allocator, hits: []const core.ots.AttestationHit) Allocator.Error![]const u8 {
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

/// One status line: the artifact's short name, its colored state, and —
/// when known — the record count and, for the embedding artifact, the
/// vector dimension.
pub fn renderStatusLine(style: Style, arena: Allocator, a: core.dstore.Artifact) Allocator.Error![]const u8 {
    const name = try prettyArtifactName(arena, a.name);
    const state = switch (a.state) {
        .fresh => try style.good(arena, "fresh"),
        .stale => try style.warn(arena, "stale"),
        .corrupt => try style.bad(arena, "corrupt"),
        .missing => try style.dim(arena, "missing"),
    };
    var line = try arena.print("{s}  {s}", .{ name, state });
    if (a.record_count) |records| {
        const detail = try arena.print(" · {d} {s}", .{ records, countNoun(records, "record", "records") });
        line = try arena.print("{s}{s}", .{ line, try style.dim(arena, detail) });
    }
    if (a.dim) |dim| {
        const detail = try arena.print(" · dim {d}", .{dim});
        line = try arena.print("{s}{s}", .{ line, try style.dim(arena, detail) });
    }
    return line;
}

/// The short name of an artifact for the status lines: `index`, `embed`,
/// `profile`, and `digest <start>..<end>`; anything else (a user-placed
/// file in the digests directory) keeps its name.
fn prettyArtifactName(allocator: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, name, "derived/index.zdi")) return "index";
    if (std.mem.eql(u8, name, "embed")) return "embed";
    if (std.mem.eql(u8, name, "profile.md")) return "profile";
    const prefix = "derived/digests/";
    if (std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, ".digest")) {
        const period = name[prefix.len .. name.len - ".digest".len];
        const sep = std.mem.lastIndexOfScalar(u8, period, '_') orelse return allocator.dupe(u8, name);
        return allocator.print("digest {s}..{s}", .{ period[0..sep], period[sep + 1 ..] });
    }
    return allocator.dupe(u8, name);
}

test "dayRule: title date, dim weekday, (today) marker, dim fill to the width" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const on = Style{ .enabled = true };
    const e = "\x1b[";
    // The `=` fill is built in a loop: ++ concatenation is comptime-only.
    var want = std.ArrayList(u8).empty;
    defer want.deinit(allocator);

    // Width 40, the head ("== " ++ "2026-01-01" ++ " " ++ "Thu") is 17: 23 fill.
    {
        try want.appendSlice(allocator, "== " ++ e ++ "1;34m2026-01-01" ++ e ++ "0m " ++ e ++ "2mThu" ++ e ++ "0m" ++ e ++ "2m");
        for (0..23) |_| try want.append(allocator, '=');
        try want.appendSlice(allocator, e ++ "0m");
        const got = try dayRule(allocator, on, "2026-01-01", "Thu", false, 40);
        defer allocator.free(got);
        try std.testing.expectEqualSlices(u8, want.items, got);
    }

    // The (today) marker shortens the fill by its display length (8): 15.
    want.clearRetainingCapacity();
    {
        try want.appendSlice(allocator, "== " ++ e ++ "1;34m2026-01-01" ++ e ++ "0m " ++ e ++ "2mThu" ++ e ++ "0m" ++ e ++ "2m (today)" ++ e ++ "0m" ++ e ++ "2m");
        for (0..15) |_| try want.append(allocator, '=');
        try want.appendSlice(allocator, e ++ "0m");
        const got = try dayRule(allocator, on, "2026-01-01", "Thu", true, 40);
        defer allocator.free(got);
        try std.testing.expectEqualSlices(u8, want.items, got);
    }

    // Styling off: no SGR at all.
    want.clearRetainingCapacity();
    {
        try want.appendSlice(allocator, "== 2026-01-01 Thu");
        for (0..23) |_| try want.append(allocator, '=');
        const got = try dayRule(allocator, Style.off, "2026-01-01", "Thu", false, 40);
        defer allocator.free(got);
        try std.testing.expectEqualSlices(u8, want.items, got);
    }

    // A width at or under the head's display length: no fill.
    const got = try dayRule(allocator, on, "2026-01-01", "Thu", false, 17);
    defer allocator.free(got);
    try std.testing.expectEqualStrings(
        "== " ++ e ++ "1;34m2026-01-01" ++ e ++ "0m " ++ e ++ "2mThu" ++ e ++ "0m",
        got,
    );
}

test "wrapText: greedy wrap, hard split, and the degenerate cases" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Greedy: words flow until the next would exceed the width (20 - 4
    // = 16 available); the continuation line is indented to column 4.
    // The results are never freed: the wrapped cases belong to the arena
    // and the degenerate cases return the input as-is (freeing that would
    // write through the allocator into read-only memory).
    const got = try wrapText(allocator, "aa bb cc dd ee ff gg", 20, 4);
    try std.testing.expectEqualStrings("aa bb cc dd ee\n    ff gg", got);

    // A word longer than the available width (8 - 2 = 6) hard-splits.
    try std.testing.expectEqualStrings("abcdef\n  ghijkl", try wrapText(allocator, "abcdefghijkl", 8, 2));

    // An embedded newline: each line wraps independently.
    try std.testing.expectEqualStrings("one two\nthree\nfour five\nsix", try wrapText(allocator, "one two three\nfour five six", 12, 0));

    // Space runs collapse; a trailing run drops.
    try std.testing.expectEqualStrings("a b c", try wrapText(allocator, "a  b   c ", 10, 0));

    // No room (width <= indent) or empty text: unchanged.
    try std.testing.expectEqualStrings("aa bb", try wrapText(allocator, "aa bb", 4, 4));
    try std.testing.expectEqualStrings("", try wrapText(allocator, "", 80, 0));
}
