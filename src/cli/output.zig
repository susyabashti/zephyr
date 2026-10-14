//! All CLI formatting and rendering: the stdout/stderr writers, the usage
//! text, hex rendering, and the FAIL/status/anchor lines the commands
//! print.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("errors.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

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

pub fn hexOf(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
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
pub fn hex12Of(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, 12);
    for (hash[0..6], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}

pub fn reportIssue(file: File, io: Io, allocator: Allocator, issue: core.journal.VerifyIssue) errors.RunError!void {
    const line = try allocator.print("FAIL: {s} seq {d} {s}: {s}", .{ issue.file, issue.seq, issue.field, issue.detail });
    try printLine(file, io, line);
}

pub fn reportTargetError(arena: Allocator, io: Io, file: File, target: u64, err: core.journal.Journal.ResolveTargetError) errors.RunError!void {
    const msg = switch (err) {
        error.TargetNotFound => try arena.print("no such entry: seq {d}", .{target}),
        error.TargetNotEntry => try arena.print("seq {d} is not an entry", .{target}),
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

pub fn renderStatusLine(arena: Allocator, a: core.dstore.Artifact) Allocator.Error![]const u8 {
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
