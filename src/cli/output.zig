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
        \\Options:
        \\  --journal PATH    journal directory (default: $ZEPHYR_HOME or
        \\                    ~/.local/share/zephyr)
        \\  --version         print version
        \\  --help            this help
        \\
    ;
    return File.writeStreamingAll(file, io, usage);
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
