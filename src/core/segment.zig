//! Segment file layout for Zephyr v1 (spec section 6).
//!
//! A journal is a directory of monthly segment files, named `<YYYY>-<MM>.zph`
//! (UTC month of the segment's first record). Each file is:
//!
//!   FileHeader(30) ‖ HeaderRegion(125 bytes/record) ‖ PayloadRegion ‖ [Footer(88)]
//!
//! Files are written atomically (ephemeral file + rename). A sealed file is
//! never modified after sealing except for payload-region redaction.

const std = @import("std");
const records = @import("records.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Magic: [4]u8 = .{ 'Z', 'P', 'H', '1' };
pub const FileHeaderLen: usize = 30;
pub const FooterLen: usize = 88;
pub const FlagSealed: u8 = 1;
pub const FlagReservedMask: u8 = 0xFE;

pub const FileHeader = struct {
    version: u8,
    sealed: bool,
    segment_start_seq: u64,
    record_count: u64,
    header_region_len: u32,
    payload_region_len: u32,
};

/// One record in file form: the stored record_hash copy, the encoded header,
/// and the raw payload bytes.
pub const RawRecord = struct {
    record_hash: [records.DigestLen]u8,
    header: [records.HeaderLen]u8,
    payload: []const u8,
};

pub const Footer = struct {
    first_seq: u64,
    last_seq: u64,
    count: u64,
    head: [records.DigestLen]u8,
    hash: [records.DigestLen]u8,
};

pub const Segment = struct {
    file_name: []const u8,
    header: FileHeader,
    /// Decoded headers in file order.
    records: []const records.Header,
    /// Raw payload bytes in file order (borrowed from `bytes`).
    payloads: []const []const u8,
    /// Present iff the file is sealed.
    footer: ?Footer,
    /// Raw file bytes; caller owns and must keep alive.
    bytes: []const u8,

    pub fn recordCount(self: *const Segment) u64 {
        return self.header.record_count;
    }

    /// The segment head: final record_hash (or genesis for an empty segment).
    pub fn head(self: *const Segment) [records.DigestLen]u8 {
        const n = self.records.len;
        if (n == 0) return records.Header.GenesisHash;
        return self.records[n - 1].record_hash;
    }

    pub fn deinit(self: *Segment, allocator: Allocator) void {
        allocator.free(self.records);
        allocator.free(self.payloads);
    }
};

/// Cheap segment view: file header fields plus the final record_hash, without
/// per-record allocation. Used to walk a journal (append, chain state).
pub const Summary = struct {
    start_seq: u64,
    record_count: u64,
    sealed: bool,
    head: [records.DigestLen]u8,
};

pub const SummaryError = error{
    FileTooShort,
    BadMagic,
    BadVersion,
    ReservedFlagBit,
    EmptySegment,
    BadHeaderRegionLen,
    SizeMismatch,
};

pub fn summary(bytes: []const u8) SummaryError!Summary {
    if (bytes.len < FileHeaderLen) return error.FileTooShort;
    if (!std.mem.eql(u8, bytes[0..4], &Magic)) return error.BadMagic;
    const version = bytes[4];
    if (version != records.FormatVersion) return error.BadVersion;
    const flags = bytes[5];
    if ((flags & FlagReservedMask) != 0) return error.ReservedFlagBit;
    const sealed = (flags & FlagSealed) != 0;
    const start_seq = records.readU64(bytes[6..14]);
    const record_count = records.readU64(bytes[14..22]);
    const header_region_len = records.readU32(bytes[22..26]);
    const payload_region_len = records.readU32(bytes[26..30]);
    if (record_count == 0) return error.EmptySegment;
    const expected_header_len = records.RecordBlockLen * record_count;
    if (expected_header_len > std.math.maxInt(u32)) return error.BadHeaderRegionLen;
    if (header_region_len != @as(u32, @intCast(expected_header_len))) {
        return error.BadHeaderRegionLen;
    }
    const header_region_end = FileHeaderLen + @as(usize, expected_header_len);
    const payload_region_end = header_region_end + @as(usize, payload_region_len);
    const expected_total = payload_region_end + if (sealed) FooterLen else 0;
    if (bytes.len != expected_total) return error.SizeMismatch;
    var head: [records.DigestLen]u8 = undefined;
    @memcpy(&head, bytes[header_region_end - records.RecordBlockLen ..][0..records.DigestLen]);
    return .{ .start_seq = start_seq, .record_count = record_count, .sealed = sealed, .head = head };
}

/// The 32-byte committed head of a sealed segment's footer (spec/ots-
/// anchor.md section 2). The file must pass `summary` and be sealed; the
/// footer's own hash check belongs to verify.
pub const FooterHeadError = SummaryError || error{NotSealed};

pub fn footerHead(bytes: []const u8) FooterHeadError![records.DigestLen]u8 {
    const sum = try summary(bytes);
    if (!sum.sealed) return error.NotSealed;
    const f = bytes.len - FooterLen;
    var head: [records.DigestLen]u8 = undefined;
    @memcpy(&head, bytes[f + 24 .. f + 56]);
    return head;
}

/// Structural parse only: magic, version, region sizes, per-record header
/// decode, payload slicing, footer fields. No chain, commitment, or footer
/// hash checks — those belong to verify (spec section 8).
pub const ParseError = records.DecodeError || std.mem.Allocator.Error || error{
    FileTooShort,
    BadMagic,
    BadVersion,
    ReservedFlagBit,
    EmptySegment,
    BadHeaderRegionLen,
    SizeMismatch,
    TruncatedPayloadRegion,
    StoredHashMismatch,
};

/// `fail_index` receives the 0-based block index of the record whose header
/// failed to decode, so callers can report the exact seq; initialize it to
/// `std.math.maxInt(usize)` to tell file-level failures apart.
pub fn parse(allocator: Allocator, file_name: []const u8, bytes: []const u8, fail_index: *usize) ParseError!Segment {
    if (bytes.len < FileHeaderLen) return error.FileTooShort;
    if (!std.mem.eql(u8, bytes[0..4], &Magic)) return error.BadMagic;
    const version = bytes[4];
    if (version != records.FormatVersion) return error.BadVersion;
    const flags = bytes[5];
    if ((flags & FlagReservedMask) != 0) return error.ReservedFlagBit;
    const sealed = (flags & FlagSealed) != 0;
    const segment_start_seq = records.readU64(bytes[6..14]);
    const record_count = records.readU64(bytes[14..22]);
    const header_region_len = records.readU32(bytes[22..26]);
    const payload_region_len = records.readU32(bytes[26..30]);

    if (record_count == 0) return error.EmptySegment;
    const expected_header_len = records.RecordBlockLen * record_count;
    if (expected_header_len > std.math.maxInt(u32)) return error.BadHeaderRegionLen;
    if (header_region_len != @as(u32, @intCast(expected_header_len))) {
        return error.BadHeaderRegionLen;
    }

    const header_region_end = FileHeaderLen + @as(usize, expected_header_len);
    const payload_region_end = header_region_end + @as(usize, payload_region_len);
    const expected_total = payload_region_end + if (sealed) FooterLen else 0;
    if (bytes.len != expected_total) return error.SizeMismatch;

    const n: usize = @intCast(record_count);
    const headers = try allocator.alloc(records.Header, n);
    errdefer allocator.free(headers);
    const payloads = try allocator.alloc([]const u8, n);
    errdefer allocator.free(payloads);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const block_start = FileHeaderLen + i * records.RecordBlockLen;
        const block = bytes[block_start .. block_start + records.RecordBlockLen];
        headers[i] = records.decodeHeader(block[32 .. 32 + records.HeaderLen]) catch |err| {
            fail_index.* = i;
            return err;
        };
        // The stored copy must match the header's own record_hash (spec section 6).
        if (!std.mem.eql(u8, block[0..32], &headers[i].record_hash)) {
            fail_index.* = i;
            return error.StoredHashMismatch;
        }
    }

    var w: usize = header_region_end;
    i = 0;
    while (i < n) : (i += 1) {
        if (w + 4 > payload_region_end) return error.TruncatedPayloadRegion;
        const payload_len = records.readU32(bytes[w .. w + 4]);
        w += 4;
        if (@as(usize, payload_len) > payload_region_end - w) {
            return error.TruncatedPayloadRegion;
        }
        payloads[i] = bytes[w .. w + payload_len];
        w += payload_len;
    }
    if (w != payload_region_end) return error.TruncatedPayloadRegion;

    var footer: ?Footer = null;
    if (sealed) {
        const f = payload_region_end;
        var head: [records.DigestLen]u8 = undefined;
        @memcpy(&head, bytes[f + 24 .. f + 56]);
        var hash: [records.DigestLen]u8 = undefined;
        @memcpy(&hash, bytes[f + 56 .. f + 88]);
        footer = Footer{
            .first_seq = records.readU64(bytes[f .. f + 8]),
            .last_seq = records.readU64(bytes[f + 8 .. f + 16]),
            .count = records.readU64(bytes[f + 16 .. f + 24]),
            .head = head,
            .hash = hash,
        };
    }

    return Segment{
        .file_name = file_name,
        .header = .{
            .version = version,
            .sealed = sealed,
            .segment_start_seq = segment_start_seq,
            .record_count = record_count,
            .header_region_len = header_region_len,
            .payload_region_len = payload_region_len,
        },
        .records = headers,
        .payloads = payloads,
        .footer = footer,
        .bytes = bytes,
    };
}

/// Assembles the complete file bytes for a segment (spec section 6). Pure
/// function of its inputs; the test vectors pin the result byte-for-byte.
pub fn renderFile(allocator: Allocator, header: *const FileHeader, recs: []const RawRecord) (Allocator.Error || error{ PayloadRegionTooLarge, EmptySegment })![]u8 {
    const n = recs.len;
    var payload_region_len: usize = 0;
    for (recs) |r| payload_region_len += 4 + r.payload.len;
    if (payload_region_len > std.math.maxInt(u32)) return error.PayloadRegionTooLarge;

    const total = FileHeaderLen + records.RecordBlockLen * n +
        payload_region_len + if (header.sealed) FooterLen else 0;
    const out = try allocator.alloc(u8, total);

    @memcpy(out[0..4], &Magic);
    out[4] = records.FormatVersion;
    out[5] = if (header.sealed) FlagSealed else 0;
    records.putU64(out[6..14], header.segment_start_seq);
    records.putU64(out[14..22], header.record_count);
    records.putU32(out[22..26], @intCast(records.RecordBlockLen * n));
    records.putU32(out[26..30], @intCast(payload_region_len));

    var w: usize = FileHeaderLen;
    for (recs) |r| {
        @memcpy(out[w .. w + records.DigestLen], &r.record_hash);
        w += records.DigestLen;
        @memcpy(out[w .. w + records.HeaderLen], &r.header);
        w += records.HeaderLen;
    }
    for (recs) |r| {
        records.putU32(out[w .. w + 4], @intCast(r.payload.len));
        w += 4;
        @memcpy(out[w .. w + r.payload.len], r.payload);
        w += r.payload.len;
    }
    if (header.sealed) {
        if (n == 0) return error.EmptySegment;
        writeFooter(out[w .. w + FooterLen], header, &recs[n - 1].record_hash);
    }
    assert(w + (if (header.sealed) FooterLen else 0) == total);
    return out;
}

/// Rebuilds a segment file with the payloads at `record_indexes` replaced
/// by the 35-byte redaction placeholder. Everything outside the payload
/// region is byte-identical; the `payload_region_len` file-header field is
/// updated (spec sections 4 and 6).
pub const RedactPayloadsError = Allocator.Error || SummaryError || error{BadRecordIndex};

pub fn redactPayloads(allocator: Allocator, bytes: []const u8, record_indexes: []const usize) RedactPayloadsError![]u8 {
    const sum = try summary(bytes);
    const n: usize = @intCast(sum.record_count);
    const header_region_end = FileHeaderLen + records.RecordBlockLen * n;
    const payload_region_len = bytes.len - header_region_end - if (sum.sealed) FooterLen else 0;

    var mark = std.ArrayList(bool).empty;
    errdefer mark.deinit(allocator);
    for (0..n) |_| try mark.append(allocator, false);
    for (record_indexes) |i| {
        if (i >= n) return error.BadRecordIndex;
        mark.items[i] = true;
    }

    // Per-record payload lengths from the stored length prefixes
    // (`summary` already validated the region boundaries).
    var lens = std.ArrayList(usize).empty;
    errdefer lens.deinit(allocator);
    var w: usize = header_region_end;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const len: usize = records.readU32(bytes[w .. w + 4]);
        w += 4 + len;
        try lens.append(allocator, len);
    }

    var new_payload_region_len: usize = 0;
    for (0..n) |k| new_payload_region_len += 4 + if (mark.items[k]) records.PlaceholderLen else lens.items[k];

    const total = FileHeaderLen + records.RecordBlockLen * n +
        new_payload_region_len + if (sum.sealed) FooterLen else 0;
    const out = try allocator.alloc(u8, total);

    // Header region byte-identical, with the payload_region_len field patched.
    @memcpy(out[0..header_region_end], bytes[0..header_region_end]);
    records.putU32(out[26..30], @intCast(new_payload_region_len));

    var dst: usize = header_region_end;
    var src: usize = header_region_end;
    i = 0;
    while (i < n) : (i += 1) {
        const len = lens.items[i];
        const redacted = mark.items[i];
        const out_len: usize = if (redacted) records.PlaceholderLen else len;
        records.putU32(out[dst .. dst + 4], @intCast(out_len));
        dst += 4;
        if (redacted) {
            @memcpy(out[dst .. dst + records.PlaceholderLen], &records.Payload.redactedPlaceholder);
        } else {
            @memcpy(out[dst .. dst + len], bytes[src + 4 .. src + 4 + len]);
        }
        dst += out_len;
        src += 4 + len;
    }

    if (sum.sealed) {
        @memcpy(out[dst .. dst + FooterLen], bytes[payload_region_len + header_region_end .. payload_region_len + header_region_end + FooterLen]);
    }
    return out;
}

/// SHA-256(first_seq ‖ last_seq ‖ count ‖ head) (spec section 5).
pub fn computeFooterHash(first_seq: u64, last_seq: u64, count: u64, head: *const [records.DigestLen]u8) [records.DigestLen]u8 {
    var hasher = records.Sha256.init(.{});
    var buf: [8]u8 = undefined;
    records.putU64(&buf, first_seq);
    hasher.update(&buf);
    records.putU64(&buf, last_seq);
    hasher.update(&buf);
    records.putU64(&buf, count);
    hasher.update(&buf);
    hasher.update(head[0..]);
    return hasher.finalResult();
}

/// Renders the 88-byte footer. `seqs` must be consecutive, so last = start + count - 1.
pub fn writeFooter(buf: []u8, header: *const FileHeader, head: *const [records.DigestLen]u8) void {
    assert(buf.len == FooterLen);
    assert(header.record_count >= 1);
    const last_seq = header.segment_start_seq + header.record_count - 1;
    records.putU64(buf[0..8], header.segment_start_seq);
    records.putU64(buf[8..16], last_seq);
    records.putU64(buf[16..24], header.record_count);
    @memcpy(buf[24..56], head);
    const hash = computeFooterHash(header.segment_start_seq, last_seq, header.record_count, head);
    @memcpy(buf[56..88], &hash);
}

/// Atomically materializes `bytes` at `dir/path` (ephemeral file + rename,
/// spec section 7).
pub const WriteError = Dir.CreateFileAtomicError || File.Atomic.ReplaceError || File.Writer.Error;

pub fn writeAtomic(dir: Dir, io: Io, path: []const u8, bytes: []const u8) WriteError!void {
    var atomic = try Dir.createFileAtomic(dir, io, path, .{
        .make_path = false,
        .replace = true,
    });
    defer atomic.deinit(io);
    try File.writeStreamingAll(atomic.file, io, bytes);
    try atomic.replace(io);
}

test "render/parse round trip, unsealed" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const salt = [records.SaltLen]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
    const payload = records.Payload{ .salt = salt, .text = "hello", .tags = &.{"a"} };
    var payload_bytes: [records.payloadSize("hello", &.{"a"})]u8 = undefined;
    records.encodePayload(&payload, &payload_bytes);

    var header = records.Header{
        .version = records.FormatVersion,
        .record_type = .entry,
        .seq = 0,
        .timestamp_ms = 1000,
        .tz_offset_min = 0,
        .flags = 0,
        .target_seq = 0,
        .commitment = records.computeCommitment(&payload_bytes),
        .record_hash = undefined,
    };
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.prefixBytes(&prefix);
    const genesis = records.Header.GenesisHash;
    header.record_hash = records.computeRecordHash(&prefix, &genesis);
    var header_bytes: [records.HeaderLen]u8 = undefined;
    records.encodeHeader(&header, &header_bytes);

    const file_header = FileHeader{
        .version = records.FormatVersion,
        .sealed = false,
        .segment_start_seq = 0,
        .record_count = 1,
        .header_region_len = records.RecordBlockLen,
        .payload_region_len = 4 + payload_bytes.len,
    };
    const raw = RawRecord{ .record_hash = header.record_hash, .header = header_bytes, .payload = &payload_bytes };
    const bytes = try renderFile(allocator, &file_header, &.{raw});
    var fail_index: usize = std.math.maxInt(usize);
    var seg = try parse(allocator, "2026-01.zph", bytes, &fail_index);
    defer seg.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), seg.recordCount());
    try std.testing.expect(!seg.header.sealed);
    const decoded = try records.decodePayload(allocator, seg.payloads[0]);
    defer allocator.free(decoded.tags);
    try std.testing.expectEqualStrings("hello", decoded.text);
}
