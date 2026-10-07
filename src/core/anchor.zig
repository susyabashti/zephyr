//! Anchor artifact format for Zephyr v1 (spec/anchor-format.md, FROZEN).
//!
//! A checkpoint record (record-format section 10) binds a journal's
//! `(head, count, timestamp_ms)` state to an Ed25519 public key. The
//! signature and key do not fit in the record, so they are stored in a
//! 190-byte artifact at `<journal>/anchors/checkpoint-<seq>.zpa` and pushed
//! to external storage. This file defines the artifact bytes, the signed
//! message, the artifact-level checks (well-formed, hash, signature), and
//! the pure chain-linkage check against a journal's header list.
//!
//! Key and seed I/O deliberately lives in the CLI: this module is pure.

const std = @import("std");
const records = @import("records.zig");

const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;

pub const Magic: [4]u8 = .{ 'Z', 'P', 'A', '1' };
pub const Version: u8 = 1;
pub const ArtifactLen: usize = 190;
/// The trailing hash covers bytes [0..HashedLen); the signature is inside it.
pub const HashedLen: usize = 158;
/// head[32] ‖ count[8 BE] ‖ timestamp_ms[8 BE]
pub const MessageLen: usize = 48;

comptime {
    assert(ArtifactLen == 6 + 32 + 32 + 8 + 8 + 8 + 64 + 32);
    assert(HashedLen == ArtifactLen - 32);
    assert(MessageLen == 32 + 8 + 8);
}

pub const Artifact = struct {
    public_key: [32]u8,
    head: [32]u8,
    count: u64,
    timestamp_ms: u64,
    checkpoint_seq: u64,
    signature: [64]u8,
    hash: [32]u8,

    /// The 48-byte signed message (spec section 4).
    pub fn signatureMessage(self: *const Artifact, buf: *[MessageLen]u8) void {
        @memcpy(buf[0..32], &self.head);
        records.putU64(buf[32..40], self.count);
        records.putU64(buf[40..48], self.timestamp_ms);
    }

    /// Lays out the full 190-byte artifact (spec section 3). `self` must be
    /// fully populated; the `hash` field is the SHA-256 of the first 158
    /// bytes of the result.
    pub fn encode(self: *const Artifact, out: *[ArtifactLen]u8) void {
        @memcpy(out[0..4], &Magic);
        out[4] = Version;
        out[5] = 0;
        @memcpy(out[6..38], &self.public_key);
        @memcpy(out[38..70], &self.head);
        records.putU64(out[70..78], self.count);
        records.putU64(out[78..86], self.timestamp_ms);
        records.putU64(out[86..94], self.checkpoint_seq);
        @memcpy(out[94..158], &self.signature);
        @memcpy(out[158..190], &self.hash);
    }
};

/// Self-verification of an artifact byte string (spec section 6, steps 1-3).
pub const VerifyError = error{
    BadLength,
    BadMagic,
    BadVersion,
    ReservedNotZero,
    NonCanonicalKey,
    BadHash,
    SignatureVerificationFailed,
};

pub fn verifyBytes(bytes: []const u8) VerifyError!Artifact {
    if (bytes.len != ArtifactLen) return error.BadLength;
    if (!std.mem.eql(u8, bytes[0..4], &Magic)) return error.BadMagic;
    if (bytes[4] != Version) return error.BadVersion;
    if (bytes[5] != 0) return error.ReservedNotZero;

    var public_key: [32]u8 = undefined;
    @memcpy(&public_key, bytes[6..38]);
    var head: [32]u8 = undefined;
    @memcpy(&head, bytes[38..70]);
    var signature: [64]u8 = undefined;
    @memcpy(&signature, bytes[94..158]);
    var hash: [32]u8 = undefined;
    @memcpy(&hash, bytes[158..190]);

    const artifact = Artifact{
        .public_key = public_key,
        .head = head,
        .count = records.readU64(bytes[70..78]),
        .timestamp_ms = records.readU64(bytes[78..86]),
        .checkpoint_seq = records.readU64(bytes[86..94]),
        .signature = signature,
        .hash = hash,
    };

    // The hash covers the signature as well, so a flipped signature byte is
    // reported as a hash failure (the hash is checked before the signature).
    var digest: [32]u8 = undefined;
    records.Sha256.hash(bytes[0..HashedLen], &digest, .{});
    if (!std.mem.eql(u8, &digest, &hash)) return error.BadHash;

    const pub_key = Ed25519.PublicKey.fromBytes(public_key) catch return error.NonCanonicalKey;
    var msg: [MessageLen]u8 = undefined;
    artifact.signatureMessage(&msg);
    const sig = Ed25519.Signature.fromBytes(signature);
    sig.verify(msg[0..], pub_key) catch return error.SignatureVerificationFailed;
    return artifact;
}

/// The Ed25519 signing failures, collapsed to one named error.
pub const SignError = error{Signature};

/// Builds the full 190-byte artifact for a checkpoint state: signs the
/// message with `kp` (deterministic) and computes the trailing hash over the
/// first 158 bytes. Same inputs always yield the same bytes.
pub fn render(
    kp: *const Ed25519.KeyPair,
    head: [32]u8,
    count: u64,
    timestamp_ms: u64,
    checkpoint_seq: u64,
) SignError![ArtifactLen]u8 {
    var partial = Artifact{
        .public_key = kp.public_key.toBytes(),
        .head = head,
        .count = count,
        .timestamp_ms = timestamp_ms,
        .checkpoint_seq = checkpoint_seq,
        .signature = @splat(0),
        .hash = @splat(0),
    };
    var msg: [MessageLen]u8 = undefined;
    partial.signatureMessage(&msg);
    const sig = kp.sign(msg[0..], null) catch |err| switch (err) {
        error.IdentityElement, error.KeyMismatch, error.NonCanonical, error.WeakPublicKey => return error.Signature,
    };
    partial.signature = sig.toBytes();
    partial.hash = @splat(0);

    var bytes: [ArtifactLen]u8 = undefined;
    partial.encode(&bytes);
    var digest: [32]u8 = undefined;
    records.Sha256.hash(bytes[0..HashedLen], &digest, .{});
    @memcpy(bytes[HashedLen..], &digest);
    return bytes;
}

/// Chain linkage (spec section 6, step 4): the journal must contain a record
/// at `checkpoint_seq` whose record_hash and timestamp match, and its total
/// record count must be at least `count`.
pub const ChainError = error{
    CountRegression,
    CheckpointMissing,
};

pub fn checkChain(artifact: *const Artifact, headers: []const records.Header) ChainError!void {
    if (artifact.count > headers.len) return error.CountRegression;
    if (artifact.checkpoint_seq >= headers.len) return error.CheckpointMissing;
    const h = headers[artifact.checkpoint_seq];
    if (!std.mem.eql(u8, &h.record_hash, &artifact.head)) return error.CheckpointMissing;
    if (h.timestamp_ms != artifact.timestamp_ms) return error.CheckpointMissing;
}
