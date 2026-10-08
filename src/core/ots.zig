//! OpenTimestamps v1 detached timestamp proofs (.ots) — verification only.
//!
//! The byte format is frozen in spec/ots-anchor.md; the normative
//! reference is opentimestamps/python-opentimestamps (modules
//! opentimestamps/core/serialize.py, op.py, notary.py, timestamp.py and
//! opentimestamps/bitcoin.py). Zephyr stamps the footer head of a sealed
//! segment: the stamped document is the 32-byte footer_head and
//! file_digest = SHA-256(footer_head).
//!
//! This module verifies the proof structure and the digest binding;
//! attestation authenticity (e.g. that a bitcoin attestation's root
//! message really is the merkle root of the claimed block) is deliberately
//! left to standard OpenTimestamps tooling (spec section 6.2).

const std = @import("std");
const records = @import("records.zig");
const Allocator = std.mem.Allocator;

comptime {
    std.debug.assert(HeaderMagic.len == 31);
}

/// The 31-byte detached-timestamp header magic (spec section 3).
pub const HeaderMagic: []const u8 = &[_]u8{
    0x00, 'O',  'p', 'e', 'n', 'T', 'i', 'm',  'e',  's',  't',  'a',  'm',  'p',  's',
    0x00, 0x00, 'P', 'r', 'o', 'o', 'f', 0x00, 0xBF, 0x89, 0xE2, 0xE8, 0x84, 0xE8, 0x92,
    0x94,
};
pub const MajorVersion: u8 = 1;
/// The only file hash op Zephyr accepts: OpSHA256 (spec section 3).
pub const HashOpSha256: u8 = 0x08;
/// The only proof-tree ops Zephyr accepts (spec section 4).
pub const OpAppend: u8 = 0xF0;
pub const OpPrepend: u8 = 0xF1;
pub const OpSha256: u8 = 0x08;
/// Attestation tags (spec section 4).
pub const BitcoinTag: [8]u8 = .{ 0x05, 0x88, 0x96, 0x0D, 0x73, 0xD7, 0x19, 0x01 };
pub const LitecoinTag: [8]u8 = .{ 0x06, 0x86, 0x9A, 0x0D, 0x73, 0xD7, 0x1B, 0x45 };
pub const PendingTag: [8]u8 = .{ 0x83, 0xDF, 0xE3, 0x0D, 0x2E, 0xF9, 0x0C, 0x8E };
/// Limits (spec section 4); MaxProofLen is local Zephyr policy.
pub const MaxProofLen: usize = 1024 * 1024;
pub const MaxMsgLen: usize = 4096;
pub const MaxOpArgLen: usize = 4096;
pub const MaxAttestationPayloadLen: usize = 8192;
pub const MaxPendingUriLen: usize = 1000;
pub const RecursionLimit: usize = 256;

pub const VerifyError = error{
    TooLarge,
    Truncated,
    TrailingGarbage,
    BadMagic,
    BadVersion,
    BadHashOp,
    DigestMismatch,
    UnknownOp,
    OpArgEmpty,
    OpArgTooLong,
    /// Defensive: unreachable while results are capped at MaxMsgLen.
    MsgTooLong,
    ResultTooLong,
    RecursionLimit,
    AttestationPayloadTooLong,
    BadAttestation,
    BadUri,
    VaruintTooLong,
};

/// One attestation found in the proof tree. `pending` payloads are owned
/// by the allocator passed to `verify`.
pub const Attestation = union(enum) {
    bitcoin: u64,
    litecoin: u64,
    pending: []const u8,
    unknown: [8]u8,
};

/// An attestation with the message of the node it sits on. `msg` is set
/// for 32-byte node messages (the case for every block attestation);
/// `null` for longer node messages.
pub const AttestationHit = struct {
    attestation: Attestation,
    msg: ?[32]u8,
};

pub const Verification = struct {
    /// The tree root; equal to the verified file digest.
    root: [32]u8,
    /// Every attestation in the tree, in tree order. Owned by the
    /// allocator passed to `verify`.
    attestations: []const AttestationHit,
};

/// Verifies a .ots proof against the expected stamped-file digest
/// (spec section 6.1). `proof` may be freed as soon as this returns;
/// the result (including pending URIs) is owned by `allocator`.
pub fn verify(allocator: Allocator, proof: []const u8, expected_digest: []const u8) (Allocator.Error || VerifyError)!Verification {
    if (proof.len > MaxProofLen) return error.TooLarge;
    var r = Reader{ .buf = proof };
    if (proof.len < HeaderMagic.len + 1 + 1 + 32) return error.Truncated;
    const magic = r.readBytes(HeaderMagic.len) catch return error.Truncated;
    if (!std.mem.eql(u8, magic, HeaderMagic)) return error.BadMagic;
    const version = try r.readByte();
    if (version != MajorVersion) return error.BadVersion;
    const hash_op = try r.readByte();
    if (hash_op != HashOpSha256) return error.BadHashOp;
    const file_digest = r.readBytes(32) catch return error.Truncated;
    if (expected_digest.len != 32 or !std.mem.eql(u8, file_digest, expected_digest)) {
        return error.DigestMismatch;
    }

    var root: [32]u8 = undefined;
    @memcpy(&root, file_digest);
    var attestations = std.ArrayList(AttestationHit).empty;
    errdefer attestations.deinit(allocator);
    try parseNode(&r, allocator, file_digest, 0, &attestations);
    if (r.pos != proof.len) return error.TrailingGarbage;
    return Verification{
        .root = root,
        .attestations = try attestations.toOwnedSlice(allocator),
    };
}

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readByte(self: *Reader) VerifyError!u8 {
        if (self.pos >= self.buf.len) return error.Truncated;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Reader, n: usize) VerifyError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    /// Unsigned LEB128 (serialize.py: read_varuint); capped at 10 bytes.
    fn readVaruint(self: *Reader) VerifyError!usize {
        var value: u64 = 0;
        var shift: u6 = 0;
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            const b = try self.readByte();
            const seven = @as(u64, b & 0x7F);
            // Only the 10th byte (shift 63) can overflow u64: it may set
            // at most bit 63.
            if (shift == 63 and seven > 1) return error.VaruintTooLong;
            value |= seven << shift;
            if (b & 0x80 == 0) return value;
            // A continuation bit on the 10th byte would need an 11th.
            if (i == 9) return error.VaruintTooLong;
            shift += 7;
        }
        return error.VaruintTooLong;
    }

    fn readVarbytes(self: *Reader, max_len: usize, min_len: usize, too_long: VerifyError) VerifyError![]const u8 {
        const n = try self.readVaruint();
        if (n < min_len) return error.OpArgEmpty;
        if (n > max_len) return too_long;
        return self.readBytes(n) catch return error.Truncated;
    }
};

fn parseNode(r: *Reader, allocator: Allocator, msg: []const u8, depth: usize, attestations: *std.ArrayList(AttestationHit)) (Allocator.Error || VerifyError)!void {
    if (depth > RecursionLimit) return error.RecursionLimit;
    var tag = try r.readByte();
    while (tag == 0xFF) : (tag = try r.readByte()) {
        const entry = try r.readByte();
        try parseEntry(r, allocator, msg, entry, depth, attestations);
    }
    try parseEntry(r, allocator, msg, tag, depth, attestations);
}

fn nodeMsg(msg: []const u8) ?[32]u8 {
    if (msg.len != 32) return null;
    var out: [32]u8 = undefined;
    @memcpy(&out, msg);
    return out;
}

fn parseEntry(r: *Reader, allocator: Allocator, msg: []const u8, entry: u8, depth: usize, attestations: *std.ArrayList(AttestationHit)) (Allocator.Error || VerifyError)!void {
    if (entry == 0x00) {
        try parseAttestation(r, allocator, msg, attestations);
        return;
    }
    switch (entry) {
        OpSha256 => {
            if (msg.len > MaxMsgLen) return error.MsgTooLong;
            var digest: [32]u8 = undefined;
            records.Sha256.hash(msg, &digest, .{});
            try parseNode(r, allocator, &digest, depth + 1, attestations);
        },
        OpAppend, OpPrepend => {
            const arg = try r.readVarbytes(MaxOpArgLen, 1, error.OpArgTooLong);
            if (msg.len > MaxMsgLen) return error.MsgTooLong;
            const child = try allocator.alloc(u8, msg.len + arg.len);
            defer allocator.free(child);
            if (entry == OpAppend) {
                @memcpy(child[0..msg.len], msg);
                @memcpy(child[msg.len..], arg);
            } else {
                @memcpy(child[0..arg.len], arg);
                @memcpy(child[arg.len..], msg);
            }
            if (child.len > MaxMsgLen) return error.ResultTooLong;
            try parseNode(r, allocator, child, depth + 1, attestations);
        },
        else => return error.UnknownOp,
    }
}

fn parseAttestation(r: *Reader, allocator: Allocator, msg: []const u8, attestations: *std.ArrayList(AttestationHit)) (Allocator.Error || VerifyError)!void {
    const tag = r.readBytes(8) catch return error.Truncated;
    const payload = try r.readVarbytes(MaxAttestationPayloadLen, 0, error.AttestationPayloadTooLong);
    var attestation: Attestation = undefined;
    if (std.mem.eql(u8, tag, &BitcoinTag)) {
        attestation = Attestation{ .bitcoin = try blockHeight(payload) };
    } else if (std.mem.eql(u8, tag, &LitecoinTag)) {
        attestation = Attestation{ .litecoin = try blockHeight(payload) };
    } else if (std.mem.eql(u8, tag, &PendingTag)) {
        var pr = Reader{ .buf = payload };
        const uri = try pr.readVarbytes(MaxPendingUriLen, 0, error.BadUri);
        for (uri) |c| {
            if (!isUriChar(c)) return error.BadUri;
        }
        if (pr.pos != payload.len) return error.BadAttestation;
        attestation = Attestation{ .pending = try allocator.dupe(u8, uri) };
    } else {
        var t: [8]u8 = undefined;
        @memcpy(&t, tag);
        attestation = Attestation{ .unknown = t };
    }
    try attestations.append(allocator, AttestationHit{ .attestation = attestation, .msg = nodeMsg(msg) });
}

/// A block attestation's payload is exactly one LEB128 height.
fn blockHeight(payload: []const u8) VerifyError!u64 {
    var r = Reader{ .buf = payload };
    const height = try r.readVaruint();
    if (r.pos != payload.len) return error.BadAttestation;
    return height;
}

fn isUriChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or
        c == '/' or c == ':';
}
