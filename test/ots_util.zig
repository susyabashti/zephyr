//! Test helpers for building synthetic .ots proofs. Shared by
//! test/ots.zig and test/phase5b.zig; not product code.
//!
//! The builder produces the linear shape every Bitcoin-backed calendar
//! proof has: one op per node, one attestation at the leaf.

const std = @import("std");
const core = @import("zephyr_core");

const ots = core.ots;
const Allocator = std.mem.Allocator;

/// Serializes `n` as an LEB128 varint at the start of `buf`; returns the
/// bytes used. `buf` must hold at least 10 bytes.
pub fn putVaruint(buf: []u8, n: u64) []u8 {
    var i: usize = 0;
    var v = n;
    while (true) {
        var b = @as(u8, @intCast(v & 0x7F));
        v >>= 7;
        if (v != 0) b |= 0x80;
        buf[i] = b;
        i += 1;
        if (v == 0) break;
    }
    return buf[0..i];
}

/// The attestation bytes for a bitcoin block attestation at `height`:
/// 8-byte tag + varbytes(LEB128 height).
pub fn bitcoinAttestation(allocator: Allocator, height: u64) Allocator.Error![]u8 {
    var buf: [8 + 1 + 10]u8 = undefined;
    var w: usize = 0;
    @memcpy(buf[w..][0..8], &ots.BitcoinTag);
    w += 8;
    const payload = putVaruint(buf[w + 1 ..], height);
    buf[w] = @intCast(payload.len);
    w += 1 + payload.len;
    return allocator.dupe(u8, buf[0..w]);
}

/// A synthetic proof over `digest`:
///   digest --sha256--> sha256(digest) --sha256--> sha256^2(digest)
/// with a single bitcoin attestation at the leaf.
pub fn syntheticProof(allocator: Allocator, digest: []const u8, height: u64) Allocator.Error![]u8 {
    std.debug.assert(digest.len == 32);
    const att = try bitcoinAttestation(allocator, height);
    defer allocator.free(att);
    var out: [65 + 3 + 19]u8 = undefined;
    var w: usize = 0;
    @memcpy(out[w..][0..ots.HeaderMagic.len], ots.HeaderMagic);
    w += ots.HeaderMagic.len;
    out[w] = ots.MajorVersion;
    w += 1;
    out[w] = ots.HashOpSha256;
    w += 1;
    @memcpy(out[w .. w + 32], digest);
    w += 32;
    out[w] = ots.OpSha256;
    w += 1;
    out[w] = ots.OpSha256;
    w += 1;
    out[w] = 0x00;
    w += 1;
    @memcpy(out[w .. w + att.len], att);
    w += att.len;
    return allocator.dupe(u8, out[0..w]);
}
