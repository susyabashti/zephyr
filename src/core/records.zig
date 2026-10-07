//! Canonical record encoding for Zephyr format v1 (spec/record-format.md, FROZEN).
//!
//! Every byte written to disk goes through this file. Two implementations
//! working only from the spec must produce identical bytes; the frozen vectors
//! in spec/vectors/journals.json pin them, and both test/vectors.zig and the
//! independent Python reference (test/reference.py) check this implementation
//! against them.

const std = @import("std");
const nfc = @import("nfc.zig");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const FormatVersion: u8 = 1;

pub const SaltLen: usize = 32;
pub const DigestLen: usize = Sha256.digest_length;
pub const HeaderPrefixLen: usize = 61;
pub const HeaderLen: usize = 93;
pub const RecordBlockLen: usize = DigestLen + HeaderLen;

pub const FlagPrivate: u8 = 1 << 0;
pub const FlagReservedMask: u8 = 0xFF ^ FlagPrivate;

pub const TzOffsetMin: i16 = -840;
pub const TzOffsetMax: i16 = 840;

pub const MaxTextBytes: usize = std.math.maxInt(u16);
pub const MaxTagCount: usize = std.math.maxInt(u8);
pub const MaxTagBytes: usize = std.math.maxInt(u8);

pub const PlaceholderLen: usize = SaltLen + 2 + 1; // 35: zero salt, empty text, zero tags

comptime {
    assert(Sha256.digest_length == 32);
    assert(HeaderPrefixLen + DigestLen == HeaderLen);
    assert(HeaderLen == 61 + 32);
    assert(RecordBlockLen == 125);
    assert(PlaceholderLen == 35);
}

pub const RecordType = enum(u8) {
    entry = 0x01,
    amendment = 0x02,
    tombstone = 0x03,
    redaction = 0x04,
    checkpoint = 0x05,

    pub fn fromRaw(raw: u8) ?RecordType {
        return switch (raw) {
            0x01 => .entry,
            0x02 => .amendment,
            0x03 => .tombstone,
            0x04 => .redaction,
            0x05 => .checkpoint,
            else => null,
        };
    }

    /// Types that carry text and tags; every other type has empty payload content.
    pub fn hasContent(self: RecordType) bool {
        return self == .entry or self == .amendment;
    }
};

pub const Header = struct {
    version: u8,
    record_type: RecordType,
    seq: u64,
    timestamp_ms: u64,
    tz_offset_min: i16,
    flags: u8,
    target_seq: u64,
    commitment: [DigestLen]u8,
    record_hash: [DigestLen]u8,

    /// Chain seed for the first record of a journal (spec section 3).
    pub const GenesisHash: [DigestLen]u8 = @splat(0);

    pub fn isPrivate(self: *const Header) bool {
        return (self.flags & FlagPrivate) != 0;
    }

    pub fn prefixBytes(self: *const Header, buf: *[HeaderPrefixLen]u8) void {
        var full: [HeaderLen]u8 = undefined;
        encodeHeader(self, &full);
        @memcpy(buf[0..], full[0..HeaderPrefixLen]);
    }
};

pub fn encodeHeader(header: *const Header, buf: []u8) void {
    assert(buf.len == HeaderLen);
    buf[0] = header.version;
    buf[1] = @backingInt(header.record_type);
    putU64(buf[2..10], header.seq);
    putU64(buf[10..18], header.timestamp_ms);
    putI16(buf[18..20], header.tz_offset_min);
    buf[20] = header.flags;
    putU64(buf[21..29], header.target_seq);
    @memcpy(buf[29..61], &header.commitment);
    @memcpy(buf[61..93], &header.record_hash);
}

pub const DecodeError = error{
    BadVersion,
    UnknownType,
    ReservedFlagBit,
    TzOutOfRange,
};

pub fn decodeHeader(bytes: []const u8) DecodeError!Header {
    assert(bytes.len == HeaderLen);
    const version = bytes[0];
    if (version != FormatVersion) return error.BadVersion;
    const record_type = RecordType.fromRaw(bytes[1]) orelse return error.UnknownType;
    const tz_offset_min = readI16(bytes[18..20]);
    if (tz_offset_min < TzOffsetMin or tz_offset_min > TzOffsetMax) return error.TzOutOfRange;
    if ((bytes[20] & FlagReservedMask) != 0) return error.ReservedFlagBit;

    var commitment: [DigestLen]u8 = undefined;
    @memcpy(&commitment, bytes[29..61]);
    var record_hash: [DigestLen]u8 = undefined;
    @memcpy(&record_hash, bytes[61..93]);
    return Header{
        .version = version,
        .record_type = record_type,
        .seq = readU64(bytes[2..10]),
        .timestamp_ms = readU64(bytes[10..18]),
        .tz_offset_min = tz_offset_min,
        .flags = bytes[20],
        .target_seq = readU64(bytes[21..29]),
        .commitment = commitment,
        .record_hash = record_hash,
    };
}

pub const Payload = struct {
    salt: [SaltLen]u8,
    /// Borrows from the input bytes.
    text: []const u8,
    /// Tag bytes borrow from the input; the slice-header array is freshly
    /// allocated (see decodePayload) and must be freed by the caller.
    tags: []const []const u8,

    /// All-zero payload written where redaction removed content (spec section 4).
    pub const redactedPlaceholder: [PlaceholderLen]u8 = @splat(0);
};

pub fn payloadSize(text: []const u8, tags: []const []const u8) usize {
    var size: usize = SaltLen + 2 + text.len + 1;
    for (tags) |tag| size += 1 + tag.len;
    return size;
}

pub fn encodePayload(payload: *const Payload, buf: []u8) void {
    assert(buf.len == payloadSize(payload.text, payload.tags));
    var w: usize = 0;
    @memcpy(buf[w .. w + SaltLen], &payload.salt);
    w += SaltLen;
    putU16(buf[w .. w + 2], @intCast(payload.text.len));
    w += 2;
    @memcpy(buf[w .. w + payload.text.len], payload.text);
    w += payload.text.len;
    buf[w] = @intCast(payload.tags.len);
    w += 1;
    for (payload.tags) |tag| {
        buf[w] = @intCast(tag.len);
        w += 1;
        @memcpy(buf[w .. w + tag.len], tag);
        w += tag.len;
    }
    assert(w == buf.len);
}

pub const DecodePayloadError = Allocator.Error || nfc.Error || error{
    Truncated,
    BadTagLength,
    DuplicateTag,
};

/// Decodes a stored payload. The returned text and tag bytes borrow from
/// `bytes`; the tags slice-header array is allocated from `allocator` and the
/// caller must free it (`allocator.free(payload.tags)`).
pub fn decodePayload(allocator: Allocator, bytes: []const u8) DecodePayloadError!Payload {
    if (bytes.len < PlaceholderLen) return error.Truncated;
    const text_len: usize = readU16(bytes[SaltLen..][0..2]);
    const text_start: usize = SaltLen + 2;
    const text_end = text_start + text_len;
    if (text_end + 1 > bytes.len) return error.Truncated;
    const text = bytes[text_start..text_end];
    const tag_count: usize = bytes[text_end];

    const tags = try allocator.alloc([]const u8, tag_count);
    errdefer allocator.free(tags);
    var w: usize = text_end + 1;
    var i: usize = 0;
    while (i < tag_count) : (i += 1) {
        if (w >= bytes.len) return error.Truncated;
        const tag_len: usize = bytes[w];
        if (tag_len == 0) return error.BadTagLength;
        w += 1;
        if (w + tag_len > bytes.len) return error.Truncated;
        const tag = bytes[w .. w + tag_len];
        try nfc.checkText(tag);
        for (tags[0..i]) |prev| {
            if (std.mem.eql(u8, prev, tag)) return error.DuplicateTag;
        }
        tags[i] = tag;
        w += tag_len;
    }
    if (w != bytes.len) return error.Truncated;
    try nfc.checkText(text);

    var salt: [SaltLen]u8 = undefined;
    @memcpy(&salt, bytes[0..SaltLen]);
    return Payload{ .salt = salt, .text = text, .tags = tags };
}

pub fn isRedactedPlaceholder(bytes: []const u8) bool {
    if (bytes.len != PlaceholderLen) return false;
    var all_zero = true;
    for (bytes) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    return all_zero;
}

/// SHA-256 over the stored payload bytes (spec section 5).
pub fn computeCommitment(payload: []const u8) [DigestLen]u8 {
    var out: [DigestLen]u8 = undefined;
    Sha256.hash(payload, &out, .{});
    return out;
}

/// SHA-256(header prefix ‖ previous record_hash) (spec section 5).
pub fn computeRecordHash(prefix: *const [HeaderPrefixLen]u8, prev_hash: *const [DigestLen]u8) [DigestLen]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(prefix[0..]);
    hasher.update(prev_hash[0..]);
    return hasher.finalResult();
}

pub const ValidateError = nfc.Error || error{
    BadVersion,
    ReservedFlagBit,
    TzOutOfRange,
    EmptyText,
    NonEmptyText,
    TagsOnEmpty,
    TextTooLong,
    EmptyTag,
    TagTooLong,
    DuplicateTag,
    TooManyTags,
    BadTargetSeq,
};

/// Writer-side checks before a record is encoded (spec sections 3.1 and 4).
/// Target existence is checked by verify; here only structural rules apply.
pub fn validate(header: *const Header, payload: *const Payload) ValidateError!void {
    if (header.version != FormatVersion) return error.BadVersion;
    if ((header.flags & FlagReservedMask) != 0) return error.ReservedFlagBit;
    if (header.tz_offset_min < TzOffsetMin or header.tz_offset_min > TzOffsetMax)
        return error.TzOutOfRange;
    if (payload.text.len > MaxTextBytes) return error.TextTooLong;
    if (payload.tags.len > MaxTagCount) return error.TooManyTags;

    const has_text = payload.text.len != 0;
    const has_tags = payload.tags.len != 0;
    switch (header.record_type) {
        .entry => {
            if (!has_text) return error.EmptyText;
            if (header.target_seq != 0) return error.BadTargetSeq;
        },
        .amendment => {
            if (!has_text) return error.EmptyText;
        },
        .tombstone, .redaction => {
            if (has_text) return error.NonEmptyText;
            if (has_tags) return error.TagsOnEmpty;
        },
        .checkpoint => {
            if (has_text) return error.NonEmptyText;
            if (has_tags) return error.TagsOnEmpty;
            if (header.target_seq != 0) return error.BadTargetSeq;
        },
    }
    // No forward or self targets (spec section 3.1).
    if (header.record_type != .entry and header.target_seq >= header.seq) {
        return error.BadTargetSeq;
    }

    try nfc.checkText(payload.text);
    for (payload.tags) |tag| {
        if (tag.len == 0) return error.EmptyTag;
        if (tag.len > MaxTagBytes) return error.TagTooLong;
        try nfc.checkText(tag);
    }
    for (payload.tags, 0..) |tag, i| {
        for (payload.tags[0..i]) |prev| {
            if (std.mem.eql(u8, prev, tag)) return error.DuplicateTag;
        }
    }
}

pub fn putU16(buf: []u8, value: u16) void {
    assert(buf.len == 2);
    writeU16(buf, value);
}

pub fn putU32(buf: []u8, value: u32) void {
    assert(buf.len == 4);
    writeU32(buf, value);
}

pub fn putU64(buf: []u8, value: u64) void {
    assert(buf.len == 8);
    writeU64(buf, value);
}

pub fn putI16(buf: []u8, value: i16) void {
    assert(buf.len == 2);
    writeI16(buf, value);
}

// Big-endian integer I/O. The 0.17 std.mem.readInt/writeInt require pointers
// to fixed-size arrays; slices (our normal case) are easier with these.
pub fn readU16(bytes: []const u8) u16 {
    assert(bytes.len == 2);
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

pub fn readU32(bytes: []const u8) u32 {
    assert(bytes.len == 4);
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | bytes[3];
}

pub fn readU64(bytes: []const u8) u64 {
    assert(bytes.len == 8);
    return @as(u64, readU32(bytes[0..4])) << 32 | readU32(bytes[4..8]);
}

pub fn readI16(bytes: []const u8) i16 {
    return @bitCast(readU16(bytes));
}

pub fn writeU16(buf: []u8, value: u16) void {
    buf[0] = @intCast(value >> 8);
    buf[1] = @intCast(value & 0xFF);
}

pub fn writeU32(buf: []u8, value: u32) void {
    buf[0] = @intCast(value >> 24);
    buf[1] = @intCast((value >> 16) & 0xFF);
    buf[2] = @intCast((value >> 8) & 0xFF);
    buf[3] = @intCast(value & 0xFF);
}

pub fn writeU64(buf: []u8, value: u64) void {
    writeU32(buf[0..4], @intCast(value >> 32));
    writeU32(buf[4..8], @intCast(value & 0xFFFFFFFF));
}

pub fn writeI16(buf: []u8, value: i16) void {
    writeU16(buf, @bitCast(value));
}

test "header encode/decode round trip" {
    var header = Header{
        .version = FormatVersion,
        .record_type = .entry,
        .seq = 42,
        .timestamp_ms = 1_789_000_000_123,
        .tz_offset_min = 120,
        .flags = FlagPrivate,
        .target_seq = 0,
        .commitment = @splat(0xAB),
        .record_hash = @splat(0xCD),
    };
    var buf: [HeaderLen]u8 = undefined;
    encodeHeader(&header, &buf);
    try std.testing.expectEqualSlices(u8, buf[29..61], &header.commitment);
    const decoded = try decodeHeader(&buf);
    try std.testing.expectEqual(header, decoded);
}

test "negative tz offset round trip" {
    const header = Header{
        .version = FormatVersion,
        .record_type = .checkpoint,
        .seq = 0,
        .timestamp_ms = 0,
        .tz_offset_min = -840,
        .flags = 0,
        .target_seq = 0,
        .commitment = @splat(0),
        .record_hash = @splat(0),
    };
    var buf: [HeaderLen]u8 = undefined;
    encodeHeader(&header, &buf);
    const decoded = try decodeHeader(&buf);
    try std.testing.expectEqual(@as(i16, -840), decoded.tz_offset_min);
}

test "decode rejects bad version, type, flags, tz" {
    var header: Header = .{
        .version = FormatVersion,
        .record_type = .entry,
        .seq = 0,
        .timestamp_ms = 0,
        .tz_offset_min = 0,
        .flags = 0,
        .target_seq = 0,
        .commitment = @splat(0),
        .record_hash = @splat(0),
    };
    var buf: [HeaderLen]u8 = undefined;
    encodeHeader(&header, &buf);
    buf[0] = 2;
    try std.testing.expectError(error.BadVersion, decodeHeader(&buf));
    buf[0] = FormatVersion;
    buf[1] = 0x06;
    try std.testing.expectError(error.UnknownType, decodeHeader(&buf));
    buf[1] = 0x01;
    buf[20] = 0x02;
    try std.testing.expectError(error.ReservedFlagBit, decodeHeader(&buf));
    buf[20] = 0;
    buf[18] = 0x04;
    buf[19] = 0x50; // +1100 min
    try std.testing.expectError(error.TzOutOfRange, decodeHeader(&buf));
}

test "payload round trip with tags" {
    const text = "hello world";
    const tags = [_][]const u8{ "work", "a" };
    var payload = Payload{ .salt = @splat(7), .text = text, .tags = &tags };
    var buf: [payloadSize(text, &tags)]u8 = undefined;
    encodePayload(&payload, &buf);
    const gpa = std.testing.allocator;
    const decoded = try decodePayload(gpa, &buf);
    defer gpa.free(decoded.tags);
    try std.testing.expectEqualStrings(text, decoded.text);
    try std.testing.expectEqual(@as(usize, 2), decoded.tags.len);
    try std.testing.expectEqualStrings("work", decoded.tags[0]);
    try std.testing.expectEqualStrings("a", decoded.tags[1]);
}

test "placeholder decodes and is detected" {
    const gpa = std.testing.allocator;
    const p = Payload.redactedPlaceholder;
    const decoded = try decodePayload(gpa, &p);
    defer gpa.free(decoded.tags);
    try std.testing.expectEqual(@as(usize, 0), decoded.text.len);
    try std.testing.expect(isRedactedPlaceholder(&p));
    try std.testing.expect(!isRedactedPlaceholder(p[0 .. p.len - 1]));
}

test "target 0 is a valid target (the first entry)" {
    var header = Header{
        .version = FormatVersion,
        .record_type = .amendment,
        .seq = 1,
        .timestamp_ms = 0,
        .tz_offset_min = 0,
        .flags = 0,
        .target_seq = 0,
        .commitment = @splat(0),
        .record_hash = @splat(0),
    };
    const text_payload = Payload{ .salt = @splat(0), .text = "x", .tags = &.{} };
    const empty_payload = Payload{ .salt = @splat(0), .text = "", .tags = &.{} };

    // Spec section 3.1 only requires the target to be strictly earlier than
    // the record, so targeting the entry at seq 0 is legal for all three
    // targeting types (the reader, verifyBytes, has always accepted it).
    try validate(&header, &text_payload);
    header.record_type = .tombstone;
    try validate(&header, &empty_payload);
    header.record_type = .redaction;
    try validate(&header, &empty_payload);

    // Forward and self targets still fail.
    header.record_type = .amendment;
    header.target_seq = 5;
    try std.testing.expectError(error.BadTargetSeq, validate(&header, &text_payload));
    header.target_seq = header.seq;
    try std.testing.expectError(error.BadTargetSeq, validate(&header, &text_payload));
}

test "commitment and chain hash are deterministic" {
    const payload = Payload.redactedPlaceholder;
    const commitment = computeCommitment(&payload);
    // Independently derived (sha256 of 35 zero bytes, checked with an external
    // SHA-256 implementation when the test was written).
    const expected: [DigestLen]u8 = [DigestLen]u8{
        0x0d, 0x55, 0x35, 0xe1, 0x3c, 0xc9, 0x70, 0x8d, 0x0f, 0xf0, 0x28, 0x9a,
        0xf2, 0xfa, 0xe2, 0x7e, 0x56, 0x4b, 0x6b, 0xcb, 0xcd, 0x92, 0x42, 0xf5,
        0x14, 0x0d, 0x96, 0x95, 0x77, 0x44, 0xa5, 0x17,
    };
    try std.testing.expectEqualSlices(u8, &expected, &commitment);

    var prefix: [HeaderPrefixLen]u8 = @splat(0);
    const genesis = Header.GenesisHash;
    const first = computeRecordHash(&prefix, &genesis);
    const second = computeRecordHash(&prefix, &first);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
