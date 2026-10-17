//! Phase 0 vector suite: the frozen byte contract.
//!
//! spec/vectors/journals.json pins two journals (raw inputs, rendered segment
//! bytes, footer hashes, the LLM view, and 13 byte corruptions with their
//! exact verify reports). This file re-derives everything from the inputs
//! using only the Zig core (no Python), so it fails if the Zig encoder,
//! verifier, or view ever drift from the frozen format. The independent
//! Python reference (test/reference.py) checks the same file.

const std = @import("std");
const options = @import("std_options");
const core = @import("zephyr_core");

const records = core.records;
const segment = core.segment;
const journal = core.journal;
const view = core.view;

const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- schema

const Vectors = struct {
    format_version: u32,
    journals: []Journal,
};

const Journal = struct {
    id: []const u8,
    description: []const u8,
    segments: []SegInput,
    corruptions: []Corruption,
    expect: Expect,
};

const SegInput = struct {
    name: []const u8,
    sealed: bool,
    records: []RecInput,
};

const RecInput = struct {
    type: []const u8,
    timestamp_ms: u64,
    tz_offset_min: i16,
    private: bool,
    target_seq: u64,
    salt_hex: []const u8,
    text: []const u8,
    tags: []const []const u8,
};

const Corruption = struct {
    description: []const u8,
    segment: []const u8,
    offset: usize,
    xor: ?u8,
    value: ?u8,
    expect: IssueExpect,
};

const IssueExpect = struct {
    ok: bool,
    file: []const u8,
    seq: u64,
    field: []const u8,
    detail: []const u8,
};

const Expect = struct {
    view: []const u8,
    segments: []NameHex,
    footer_hashes: []NameHash,
};

const NameHex = struct {
    name: []const u8,
    hex: []const u8,
};

const NameHash = struct {
    name: []const u8,
    hash: []const u8,
};

// ---------------------------------------------------------------- load

fn loadVectors(allocator: Allocator) anyerror!Vectors {
    const bytes = try Dir.cwd().readFileAlloc(std.testing.io, options.vectors, allocator, .unlimited);
    return std.json.parseFromSliceLeaky(Vectors, allocator, bytes, .{});
}

// ---------------------------------------------------------------- build

/// A record fully derived from its vector input: the decoded header struct
/// (for the view) and the file-form raw record (for rendering).
const Built = struct {
    header: records.Header,
    raw: segment.RawRecord,
};

const BuildError = Allocator.Error || records.ValidateError || error{BadSalt};

fn recordType(name: []const u8) records.RecordType {
    const table = comptime [_]struct { name: []const u8, rtype: records.RecordType }{
        .{ .name = "entry", .rtype = .entry },
        .{ .name = "amendment", .rtype = .amendment },
        .{ .name = "tombstone", .rtype = .tombstone },
        .{ .name = "redaction", .rtype = .redaction },
        .{ .name = "checkpoint", .rtype = .checkpoint },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.name, name)) return row.rtype;
    }
    @panic("unknown record type in vector input");
}

fn buildRaw(allocator: Allocator, seq: u64, prev: [records.DigestLen]u8, rec: RecInput) BuildError!Built {
    var salt: [records.SaltLen]u8 = undefined;
    decodeHex(&salt, rec.salt_hex) catch return error.BadSalt;

    const payload = records.Payload{ .salt = salt, .text = rec.text, .tags = rec.tags };
    const payload_bytes = try allocator.alloc(u8, records.payloadSize(rec.text, rec.tags));
    records.encodePayload(&payload, payload_bytes);

    var header = records.Header{
        .version = records.FormatVersion,
        .record_type = recordType(rec.type),
        .seq = seq,
        .timestamp_ms = rec.timestamp_ms,
        .tz_offset_min = rec.tz_offset_min,
        .flags = if (rec.private) records.FlagPrivate else 0,
        .target_seq = rec.target_seq,
        .commitment = records.computeCommitment(payload_bytes),
        .record_hash = undefined,
    };
    try records.validate(&header, &payload);
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.prefixBytes(&prefix);
    header.record_hash = records.computeRecordHash(&prefix, &prev);
    var header_bytes: [records.HeaderLen]u8 = undefined;
    records.encodeHeader(&header, &header_bytes);
    return Built{
        .header = header,
        .raw = segment.RawRecord{
            .record_hash = header.record_hash,
            .header = header_bytes,
            .payload = payload_bytes,
        },
    };
}

// ---------------------------------------------------------------- check

const CheckError = Allocator.Error || error{TestExpectedEqual} || records.ValidateError || journal.VerifyBytesError || view.RenderError ||
    error{
        BadSalt,
        PayloadRegionTooLarge,
        EmptySegment,
        SegmentMissing,
        SegmentMismatch,
        FooterMissing,
        FooterMismatch,
        ViewMismatch,
        VerifyMismatch,
        CorruptionMismatch,
        HexLength,
        HexDigit,
    };

fn checkJournal(allocator: Allocator, j: *const Journal) CheckError!void {
    // Pass 1: derive every record from the inputs, chaining from genesis
    // across segment boundaries (spec section 3).
    var built = std.ArrayList(Built).empty;
    errdefer built.deinit(allocator);
    var headers = std.ArrayList(records.Header).empty;
    errdefer headers.deinit(allocator);
    var prev: [records.DigestLen]u8 = records.Header.GenesisHash;
    var seq: u64 = 0;
    for (j.segments) |seg| {
        for (seg.records) |rec| {
            const b = try buildRaw(allocator, seq, prev, rec);
            try built.append(allocator, b);
            try headers.append(allocator, b.header);
            prev = b.raw.record_hash;
            seq += 1;
        }
    }
    const head = prev;

    // Redaction closure: a redaction replaces the stored payload of its
    // target entry and of every amendment on that entry; headers keep the
    // commitments of the original payloads (spec sections 3 and 4).
    const n: usize = @intCast(seq);
    var replaced = std.ArrayList(bool).empty;
    errdefer replaced.deinit(allocator);
    for (0..n) |_| try replaced.append(allocator, false);
    for (built.items) |b| {
        if (b.header.record_type != .redaction) continue;
        const t: usize = @intCast(b.header.target_seq);
        replaced.items[t] = true;
        for (built.items) |other| {
            if (other.header.record_type == .amendment and other.header.target_seq == b.header.target_seq) {
                replaced.items[other.header.seq] = true;
            }
        }
    }

    // Pass 2: render each segment file, applying the closure to stored payloads.
    var files = std.ArrayList(journal.verifyFile).empty;
    errdefer files.deinit(allocator);
    var stored = std.ArrayList([]const u8).empty; // journal order, for the view
    errdefer stored.deinit(allocator);

    var cursor: usize = 0;
    for (j.segments) |seg| {
        const count: usize = seg.records.len;
        var seg_payload_region_len: usize = 0;
        var raws = std.ArrayList(segment.RawRecord).empty;
        defer raws.deinit(allocator);
        for (0..count) |i| {
            const idx: usize = cursor + i;
            const payload: []const u8 = if (replaced.items[idx])
                &records.Payload.redactedPlaceholder
            else
                built.items[idx].raw.payload;
            seg_payload_region_len += 4 + payload.len;
            try raws.append(allocator, segment.RawRecord{
                .record_hash = built.items[idx].raw.record_hash,
                .header = built.items[idx].raw.header,
                .payload = payload,
            });
            try stored.append(allocator, payload);
        }
        const file_header = segment.FileHeader{
            .version = records.FormatVersion,
            .sealed = seg.sealed,
            .segment_start_seq = @intCast(cursor),
            .record_count = @intCast(count),
            .header_region_len = @intCast(records.RecordBlockLen * count),
            .payload_region_len = @intCast(seg_payload_region_len),
        };
        const bytes = try segment.renderFile(allocator, &file_header, raws.items);
        try files.append(allocator, .{ .name = seg.name, .bytes = bytes });
        cursor += count;
    }

    // Pinned segment bytes, byte for byte.
    try std.testing.expectEqual(@as(usize, files.items.len), j.expect.segments.len);
    for (j.expect.segments) |e| {
        const file = findFile(files.items, e.name) orelse return error.SegmentMissing;
        const expected = try allocator.alloc(u8, e.hex.len / 2);
        decodeHex(expected, e.hex) catch return error.HexLength;
        if (!std.mem.eql(u8, expected, file.bytes)) {
            std.debug.print("{s}: segment {s} bytes differ from pinned vector\n", .{ j.id, e.name });
            return error.SegmentMismatch;
        }
    }

    // Pinned footer hashes (sealed segments only).
    for (j.expect.footer_hashes) |e| {
        const file = findFile(files.items, e.name) orelse return error.FooterMissing;
        if (file.bytes.len < 32) return error.FooterMismatch;
        var expected: [records.DigestLen]u8 = undefined;
        decodeHex(&expected, e.hash) catch return error.HexLength;
        if (!std.mem.eql(u8, &expected, file.bytes[file.bytes.len - 32 ..])) {
            std.debug.print("{s}: footer hash of {s} differs from pinned vector\n", .{ j.id, e.name });
            return error.FooterMismatch;
        }
    }

    // The clean journal must verify, with the head the chain produced.
    const result = try journal.verifyBytes(allocator, files.items, null);
    if (!result.ok) {
        const iss = result.issue.?;
        std.debug.print("{s}: clean journal failed verify: {s} seq {d} {s} ({s})\n", .{
            j.id, iss.file, iss.seq, iss.field, iss.detail,
        });
        return error.VerifyMismatch;
    }
    try std.testing.expectEqualSlices(u8, &head, &result.head);
    try std.testing.expectEqual(n, result.record_count);

    // The pinned LLM view.
    const rendered_view = try view.render(allocator, headers.items, stored.items);
    if (!std.mem.eql(u8, rendered_view, j.expect.view)) {
        std.debug.print("{s}: view mismatch\n--- got ---\n{s}--- want ---\n{s}\n", .{
            j.id, rendered_view, j.expect.view,
        });
        return error.ViewMismatch;
    }

    // Every corruption must fail verify with the exact pinned report.
    for (j.corruptions, 0..) |c, i| {
        const src = findFile(files.items, c.segment) orelse return error.SegmentMissing;
        const data = try allocator.dupe(u8, src.bytes);
        if (c.xor != null) {
            data[c.offset] ^= c.xor.?;
        } else {
            data[c.offset] = c.value.?;
        }

        var modified = std.ArrayList(journal.verifyFile).empty;
        defer modified.deinit(allocator);
        for (files.items) |f| {
            try modified.append(allocator, .{
                .name = f.name,
                .bytes = if (std.mem.eql(u8, f.name, c.segment)) data else f.bytes,
            });
        }
        const r = try journal.verifyBytes(allocator, modified.items, null);
        if (c.expect.ok) {
            if (!r.ok) {
                std.debug.print("{s}: corruption {d} ({s}) unexpectedly failed verify\n", .{ j.id, i, c.description });
                return error.CorruptionMismatch;
            }
            continue;
        }
        const iss = r.issue orelse return error.CorruptionMismatch;
        const match = r.ok == false and
            std.mem.eql(u8, iss.file, c.expect.file) and
            iss.seq == c.expect.seq and
            std.mem.eql(u8, iss.field, c.expect.field) and
            std.mem.eql(u8, iss.detail, c.expect.detail);
        if (!match) {
            std.debug.print("{s}: corruption {d} ({s}) reported (file={s} seq={d} field={s} detail={s}), want (file={s} seq={d} field={s} detail={s})\n", .{
                j.id,           i,               c.description,
                iss.file,       iss.seq,         iss.field,
                iss.detail,     c.expect.file,   c.expect.seq,
                c.expect.field, c.expect.detail,
            });
            return error.CorruptionMismatch;
        }
    }
}

fn findFile(files: []const journal.verifyFile, name: []const u8) ?journal.verifyFile {
    for (files) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// ---------------------------------------------------------------- hex

fn decodeHex(dst: []u8, src: []const u8) !void {
    if (src.len % 2 != 0 or dst.len * 2 != src.len) return error.HexLength;
    for (dst, 0..) |*d, i| {
        const hi = hexDigit(src[i * 2]) orelse return error.HexDigit;
        const lo = hexDigit(src[i * 2 + 1]) orelse return error.HexDigit;
        d.* = hi * 16 + lo;
    }
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ---------------------------------------------------------------- suite

test "vectors: frozen byte contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vectors = try loadVectors(allocator);
    try std.testing.expectEqual(@as(u32, 1), vectors.format_version);
    try std.testing.expect(vectors.journals.len >= 1);
    for (vectors.journals) |j| {
        try checkJournal(allocator, &j);
    }
}
