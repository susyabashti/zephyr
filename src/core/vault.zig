//! Journal encryption (spec/encryption.md): the payload v2 envelope, the
//! per-record HKDF key derivation, and the journal meta file format.
//!
//! Pure byte-level functions: key material arrives and leaves as bytes. No
//! I/O and no key storage — choosing where a master key lives is the key
//! module's job; this file only defines the format contract.

const std = @import("std");
const records = @import("records.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

/// Master key length in bytes (256 bits).
pub const KeyLen: usize = 32;
/// Envelope nonce length in bytes (XChaCha20-Poly1305 nonce).
pub const NonceLen: usize = 24;
/// AEAD tag length in bytes.
pub const TagLen: usize = 16;
/// AAD length: the record header prefix bytes [0..29)
/// (version, type, seq, timestamp_ms, tz_offset_min, flags, target_seq).
pub const AadLen: usize = 29;
/// The stored format byte of a sealed payload (spec/encryption.md section 2).
pub const FormatV2: u8 = 2;
/// Envelope overhead: 1 (format) + 24 (nonce) + 16 (tag).
pub const EnvelopeOverhead: usize = 1 + NonceLen + TagLen;

/// The redacted placeholder for a v2 journal: the all-zero envelope
/// (spec/encryption.md section 2).
pub const placeholderV2: [EnvelopeOverhead]u8 = @splat(0);

/// Meta file layout (spec/encryption.md section 3.1).
pub const MetaMagic: [4]u8 = .{ 'Z', 'P', 'M', '1' };
pub const MetaVersion: u8 = 1;
pub const MetaFileName: []const u8 = "zephyr.meta";
/// Key file (store 0) name and id (spec/encryption.md section 3.2).
pub const KeyFileName: []const u8 = "zephyr.key";
/// Keychain (store 1) service and the master account (section 3.3).
pub const KeychainService: []const u8 = "com.zephyr.journal";
pub const KeychainMasterAccount: []const u8 = "master-v1";

/// Where the master key lives. A journal's meta file pins exactly one store.
pub const Store = enum(u8) {
    keyfile = 0,
    keychain = 1,
};

pub const Meta = struct {
    store: Store,
    /// Owned by the caller's allocator (ASCII, 1–255 bytes).
    key_id: []const u8,
};

pub const MetaError = Allocator.Error || error{
    BadMagic,
    BadVersion,
    BadStore,
    /// key_id is empty or longer than 255 bytes.
    BadKeyLength,
    /// The meta bytes are shorter than the declared key_id length.
    Truncated,
    /// key_id contains a non-ASCII byte.
    NonAscii,
};

/// Encodes a meta file (spec/encryption.md section 3.1).
pub fn encodeMeta(allocator: Allocator, store: Store, key_id: []const u8) MetaError![]u8 {
    if (key_id.len == 0 or key_id.len > 255) return error.BadKeyLength;
    for (key_id) |b| if (b > 0x7F) return error.NonAscii;
    const out = try allocator.alloc(u8, 8 + key_id.len);
    @memcpy(out[0..4], &MetaMagic);
    out[4] = MetaVersion;
    out[5] = @backingInt(store);
    records.putU16(out[6..8], @intCast(key_id.len));
    @memcpy(out[8..], key_id);
    return out;
}

/// Decodes a meta file (spec/encryption.md section 3.1). The returned
/// `key_id` is owned by `allocator`.
pub fn decodeMeta(allocator: Allocator, bytes: []const u8) MetaError!Meta {
    if (bytes.len < 8) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &MetaMagic)) return error.BadMagic;
    if (bytes[4] != MetaVersion) return error.BadVersion;
    const store = std.enums.fromInt(Store, bytes[5]) orelse return error.BadStore;
    const id_len: usize = records.readU16(bytes[6..8]);
    if (id_len == 0 or id_len > 255) return error.BadKeyLength;
    if (bytes.len != 8 + id_len) return error.Truncated;
    for (bytes[8..]) |b| if (b > 0x7F) return error.NonAscii;
    return Meta{ .store = store, .key_id = try allocator.dupe(u8, bytes[8..]) };
}

/// The record header prefix bytes [0..29) — the AEAD associated data
/// (spec/encryption.md section 2).
pub fn aadOf(header: *const records.Header) [AadLen]u8 {
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.prefixBytes(&prefix);
    var aad: [AadLen]u8 = undefined;
    @memcpy(&aad, prefix[0..AadLen]);
    return aad;
}

/// The per-record AEAD key: HKDF-SHA256-Expand(PRK = master, info = nonce)
/// (spec/encryption.md section 2; RFC 5869).
pub fn recordKey(master: *const [KeyLen]u8, nonce: *const [NonceLen]u8) [KeyLen]u8 {
    var key: [KeyLen]u8 = undefined;
    Hkdf.expand(&key, nonce, master.*);
    return key;
}

/// The size of the envelope sealing `plaintext_len` bytes.
pub fn envelopeSize(plaintext_len: usize) usize {
    return EnvelopeOverhead + plaintext_len;
}

/// The plaintext length held by a well-shaped envelope.
pub fn bodyLength(envelope: []const u8) error{ Truncated, BadFormat }!usize {
    if (envelope.len < EnvelopeOverhead) return error.Truncated;
    if (envelope[0] != FormatV2) return error.BadFormat;
    return envelope.len - EnvelopeOverhead;
}

/// The redacted placeholder of a v2 journal (all-zero envelope).
pub fn isPlaceholderV2(bytes: []const u8) bool {
    if (bytes.len != EnvelopeOverhead) return false;
    for (bytes) |b| if (b != 0) return false;
    return true;
}

/// Seals `plaintext` under `master` with the given `nonce` and AAD, and
/// returns the owned envelope `[0x02][nonce][ciphertext][tag]`
/// (spec/encryption.md section 2).
pub fn seal(
    allocator: Allocator,
    master: *const [KeyLen]u8,
    nonce: [NonceLen]u8,
    aad: []const u8,
    plaintext: []const u8,
) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, envelopeSize(plaintext.len));
    out[0] = FormatV2;
    @memcpy(out[1 .. 1 + NonceLen], &nonce);
    const key = recordKey(master, &nonce);
    var tag: [TagLen]u8 = undefined;
    Aead.encrypt(out[1 + NonceLen .. 1 + NonceLen + plaintext.len], &tag, plaintext, aad, nonce, key);
    @memcpy(out[1 + NonceLen + plaintext.len ..], &tag);
    return out;
}

pub const OpenError = Allocator.Error || error{
    Truncated,
    BadFormat,
    /// The AAD did not authenticate.
    AuthenticationFailed,
};

/// Opens a v2 envelope under `master` (spec/encryption.md section 2) and
/// returns the owned plaintext. Fails with `AuthenticationFailed` when the
/// envelope, its tag, or the AAD do not authenticate.
pub fn open(allocator: Allocator, master: *const [KeyLen]u8, aad: []const u8, envelope: []const u8) OpenError![]u8 {
    const body_len = try bodyLength(envelope);
    var nonce: [NonceLen]u8 = undefined;
    @memcpy(&nonce, envelope[1 .. 1 + NonceLen]);
    const cipher = envelope[1 + NonceLen .. envelope.len - TagLen];
    var tag: [TagLen]u8 = undefined;
    @memcpy(&tag, envelope[envelope.len - TagLen ..]);
    const out = try allocator.alloc(u8, body_len);
    errdefer allocator.free(out);
    const key = recordKey(master, &nonce);
    Aead.decrypt(out, cipher, tag, aad, nonce, key) catch |err| switch (err) {
        error.AuthenticationFailed => return error.AuthenticationFailed,
    };
    return out;
}

test "meta encode/decode round trip" {
    const allocator = std.testing.allocator;
    for (&[_][]const u8{ "zephyr.key", "master-v1" }) |id| {
        const store = if (std.mem.eql(u8, id, "zephyr.key")) Store.keyfile else Store.keychain;
        const bytes = try encodeMeta(allocator, store, id);
        defer allocator.free(bytes);
        try std.testing.expectEqual(@as(u32, 0x5A504D31), records.readU32(bytes[0..4]));
        const meta = try decodeMeta(allocator, bytes);
        defer allocator.free(meta.key_id);
        try std.testing.expectEqual(store, meta.store);
        try std.testing.expectEqualStrings(id, meta.key_id);
    }
}

fn expectMetaError(buf: []u8, expected: MetaError) !void {
    const allocator = std.testing.allocator;
    defer allocator.free(buf);
    try std.testing.expectError(expected, decodeMeta(allocator, buf));
}

test "meta decode rejects malformed bytes" {
    const allocator = std.testing.allocator;
    const good = try encodeMeta(allocator, .keychain, "master-v1");
    defer allocator.free(good);

    var buf = try allocator.dupe(u8, good);
    buf[0] ^= 0xFF; // bad magic
    try expectMetaError(buf, error.BadMagic);

    buf = try allocator.dupe(u8, good);
    buf[4] = 2; // bad version
    try expectMetaError(buf, error.BadVersion);

    buf = try allocator.dupe(u8, good);
    buf[5] = 7; // unknown store
    try expectMetaError(buf, error.BadStore);

    try std.testing.expectError(error.Truncated, decodeMeta(allocator, good[0..7]));

    buf = try allocator.dupe(u8, good);
    buf[9] = 0x80; // non-ASCII id
    try expectMetaError(buf, error.NonAscii);
    try std.testing.expectError(error.BadKeyLength, encodeMeta(allocator, .keyfile, ""));
}

test "envelope round trip and negative auth" {
    const allocator = std.testing.allocator;
    var master: [KeyLen]u8 = undefined;
    @memset(&master, 0x5A);
    var nonce: [NonceLen]u8 = undefined;
    @memset(&nonce, 0x11);
    const aad: [AadLen]u8 = @splat(0x77);
    const plaintext = "hello, encrypted world";

    const envelope = try seal(allocator, &master, nonce, &aad, plaintext);
    defer allocator.free(envelope);
    try std.testing.expectEqual(@as(usize, 1 + NonceLen + plaintext.len + TagLen), envelope.len);
    try std.testing.expectEqual(@as(u8, FormatV2), envelope[0]);
    try std.testing.expect(std.mem.eql(u8, envelope[1 .. 1 + NonceLen], &nonce));

    const body = try open(allocator, &master, &aad, envelope);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(plaintext, body);

    // Wrong key.
    var other: [KeyLen]u8 = undefined;
    @memset(&other, 0x5B);
    try std.testing.expectError(error.AuthenticationFailed, open(allocator, &other, &aad, envelope));

    // Wrong AAD (the envelope is bound to the record identity).
    var aad2 = aad;
    aad2[0] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, open(allocator, &master, &aad2, envelope));

    // Corrupted tag.
    {
        var corrupted = try allocator.dupe(u8, envelope);
        defer allocator.free(corrupted);
        corrupted[corrupted.len - 1] ^= 1;
        try std.testing.expectError(error.AuthenticationFailed, open(allocator, &master, &aad, corrupted));
    }

    // Corrupted ciphertext.
    {
        var corrupted = try allocator.dupe(u8, envelope);
        defer allocator.free(corrupted);
        corrupted[1 + NonceLen] ^= 1;
        try std.testing.expectError(error.AuthenticationFailed, open(allocator, &master, &aad, corrupted));
    }

    // Not an envelope at all: too short, or a wrong format byte in a
    // well-sized envelope.
    try std.testing.expectError(error.Truncated, open(allocator, &master, &aad, &.{ 0x01, 0x02 }));
    try std.testing.expectError(error.Truncated, open(allocator, &master, &aad, envelope[0..10]));
    var bad_format = try allocator.dupe(u8, envelope);
    defer allocator.free(bad_format);
    bad_format[0] = 0x01;
    try std.testing.expectError(error.BadFormat, open(allocator, &master, &aad, bad_format));
}

test "empty plaintext round trip" {
    const allocator = std.testing.allocator;
    var master: [KeyLen]u8 = undefined;
    @memset(&master, 9);
    var nonce: [NonceLen]u8 = undefined;
    @memset(&nonce, 3);
    const aad: [AadLen]u8 = @splat(0);

    const envelope = try seal(allocator, &master, nonce, &aad, &.{});
    defer allocator.free(envelope);
    try std.testing.expectEqual(@as(usize, EnvelopeOverhead), envelope.len);

    const body = try open(allocator, &master, &aad, envelope);
    defer allocator.free(body);
    try std.testing.expectEqual(@as(usize, 0), body.len);
}

test "distinct nonces yield distinct record keys and envelopes" {
    const allocator = std.testing.allocator;
    var master: [KeyLen]u8 = undefined;
    @memset(&master, 0x42);
    var n1: [NonceLen]u8 = undefined;
    @memset(&n1, 1);
    var n2: [NonceLen]u8 = undefined;
    @memset(&n2, 2);
    const aad: [AadLen]u8 = @splat(0);
    const text = "same text";

    try std.testing.expect(!std.mem.eql(u8, &recordKey(&master, &n1), &recordKey(&master, &n2)));

    const e1 = try seal(allocator, &master, n1, &aad, text);
    defer allocator.free(e1);
    const e2 = try seal(allocator, &master, n2, &aad, text);
    defer allocator.free(e2);
    try std.testing.expect(!std.mem.eql(u8, e1, e2));
    // Each envelope still opens under its own nonce.
    const b1 = try open(allocator, &master, &aad, e1);
    defer allocator.free(b1);
    const b2 = try open(allocator, &master, &aad, e2);
    defer allocator.free(b2);
    try std.testing.expectEqualStrings(text, b1);
    try std.testing.expectEqualStrings(text, b2);
}

test "placeholder v2 detection" {
    try std.testing.expect(isPlaceholderV2(&placeholderV2));
    var almost = placeholderV2;
    almost[0] = FormatV2; // a real (unsealed) envelope byte, not all zero
    try std.testing.expect(!isPlaceholderV2(&almost));
    try std.testing.expect(!isPlaceholderV2(placeholderV2[0..40]));
    try std.testing.expect(!isPlaceholderV2(&.{ 0x00, 0x01, 0x02 }));
}
