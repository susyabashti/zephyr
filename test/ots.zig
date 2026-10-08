//! Phase 5b vector suite: OpenTimestamps v1 detached proofs (.ots).
//!
//! spec/vectors/ots.json pins two proofs (a real mainnet block 586 and a
//! synthetic single-coinbase block) that the core ots module must verify:
//! the tree root must be the stamped file digest and the leaf attestation
//! message must be the block's merkle root. This suite also runs the
//! corruption suite (mirroring test/otsref.py) and the format edge cases.
//! The independent Python reference (test/reference.py, via test/otsref.py)
//! checks the same file.

const std = @import("std");
const options = @import("std_options");
const core = @import("zephyr_core");
const ots_util = @import("ots_util.zig");

const ots = core.ots;
const records = core.records;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- schema

const OtsVectors = struct {
    format_version: u32,
    vectors: []OtsVector,
};

const OtsVector = struct {
    id: []const u8,
    source: []const u8,
    document_hex: ?[]const u8,
    file_digest_hex: []const u8,
    block_hex: []const u8,
    block_height: u32,
    expected: OtsExpected,
    proof_hex: []const u8,
};

const OtsExpected = struct {
    root_hex: []const u8,
    attestations: []OtsAttestationExpect,
};

const OtsAttestationExpect = struct {
    kind: []const u8,
    height: ?u32,
};

// ---------------------------------------------------------------- load

fn loadVectors(allocator: Allocator) anyerror!OtsVectors {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.ots_vectors, allocator, .unlimited);
    return std.json.parseFromSliceLeaky(OtsVectors, allocator, bytes, .{});
}

// ---------------------------------------------------------------- helpers

const HexError = error{ HexLength, HexDigit };

const CheckError = Allocator.Error || HexError || ots.VerifyError || error{CheckFailed};

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn hexToBytes(allocator: Allocator, hex: []const u8) (Allocator.Error || HexError)![]u8 {
    if (hex.len % 2 != 0) return error.HexLength;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    for (out, 0..) |*b, i| {
        const hi = hexDigit(hex[i * 2]) orelse return error.HexDigit;
        const lo = hexDigit(hex[i * 2 + 1]) orelse return error.HexDigit;
        b.* = hi * 16 + lo;
    }
    return out;
}

fn hexToBytes32(hex: []const u8) HexError![32]u8 {
    if (hex.len != 64) return error.HexLength;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| {
        const hi = hexDigit(hex[i * 2]) orelse return error.HexDigit;
        const lo = hexDigit(hex[i * 2 + 1]) orelse return error.HexDigit;
        b.* = hi * 16 + lo;
    }
    return out;
}

/// Header (magic + version + sha256 op + 32-byte file digest) followed by
/// `tree` (the op/attestation bytes).
fn buildProof(allocator: Allocator, digest: []const u8, tree: []const u8) Allocator.Error![]u8 {
    std.debug.assert(digest.len == 32);
    const out = try allocator.alloc(u8, ots.HeaderMagic.len + 2 + 32 + tree.len);
    errdefer allocator.free(out);
    var w: usize = 0;
    @memcpy(out[w .. w + ots.HeaderMagic.len], ots.HeaderMagic);
    w += ots.HeaderMagic.len;
    out[w] = ots.MajorVersion;
    w += 1;
    out[w] = ots.HashOpSha256;
    w += 1;
    @memcpy(out[w .. w + 32], digest);
    w += 32;
    @memcpy(out[w .. w + tree.len], tree);
    w += tree.len;
    return out[0..w];
}

/// varbytes: LEB128 length (up to 10 bytes) followed by `data`.
fn varbytes(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    var lenbuf: [10]u8 = undefined;
    const len = ots_util.putVaruint(&lenbuf, data.len);
    const out = try allocator.alloc(u8, len.len + data.len);
    errdefer allocator.free(out);
    @memcpy(out[0..len.len], len);
    @memcpy(out[len.len..], data);
    return out;
}

/// One attestation's bytes: 8-byte `tag` + varbytes(`payload`).
fn attestation(allocator: Allocator, tag: [8]u8, payload: []const u8) Allocator.Error![]u8 {
    const vb = try varbytes(allocator, payload);
    defer allocator.free(vb);
    const out = try allocator.alloc(u8, 8 + vb.len);
    errdefer allocator.free(out);
    @memcpy(out[0..8], &tag);
    @memcpy(out[8..], vb);
    return out;
}

/// varbytes(LEB128 `height`).
fn heightPayload(allocator: Allocator, height: u64) Allocator.Error![]u8 {
    var buf: [10]u8 = undefined;
    const v = ots_util.putVaruint(&buf, height);
    return allocator.dupe(u8, v);
}

/// A leaf entry: the final entry marker (0x00) plus `att` bytes.
fn leaf(allocator: Allocator, att: []const u8) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, 1 + att.len);
    errdefer allocator.free(out);
    out[0] = 0x00;
    @memcpy(out[1..], att);
    return out;
}

/// Concatenates the parts.
fn concat(allocator: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    var w: usize = 0;
    for (parts) |p| {
        @memcpy(out[w .. w + p.len], p);
        w += p.len;
    }
    return out;
}

fn sha256(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    records.Sha256.hash(input, &out, .{});
    return out;
}

// ---------------------------------------------------------------- tests

test "ots: pinned vectors verify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vectors = try loadVectors(allocator);
    try std.testing.expectEqual(@as(u32, 1), vectors.format_version);
    try std.testing.expectEqual(@as(usize, 2), vectors.vectors.len);

    for (vectors.vectors) |v| {
        const file_digest = try hexToBytes32(v.file_digest_hex);
        const root = try hexToBytes32(v.expected.root_hex);

        // A bound document must hash to the file digest.
        if (v.document_hex) |doc_hex| {
            const doc = try hexToBytes(allocator, doc_hex);
            try std.testing.expectEqualSlices(u8, &file_digest, &sha256(doc));
        }

        const proof = try hexToBytes(allocator, v.proof_hex);
        const verification = try ots.verify(allocator, proof, &file_digest);

        // The tree root is the stamped file digest...
        try std.testing.expectEqualSlices(u8, &file_digest, &verification.root);

        // ...and the attestations match the pinned expectation; every
        // block attestation sits on the node whose message is the block's
        // merkle root (pinned as expected.root_hex).
        try std.testing.expectEqual(v.expected.attestations.len, verification.attestations.len);
        for (verification.attestations, v.expected.attestations) |hit, want| {
            const want_height = want.height orelse {
                std.debug.print("{s}: unexpected null height\n", .{v.id});
                return error.CheckFailed;
            };
            switch (hit.attestation) {
                .bitcoin => |h| {
                    try std.testing.expectEqualStrings("bitcoin", want.kind);
                    try std.testing.expectEqual(want_height, h);
                },
                .litecoin => |h| {
                    try std.testing.expectEqualStrings("litecoin", want.kind);
                    try std.testing.expectEqual(want_height, h);
                },
                .pending => |uri| {
                    try std.testing.expectEqualStrings("pending", want.kind);
                    _ = uri;
                },
                .unknown => {
                    try std.testing.expectEqualStrings("unknown", want.kind);
                },
            }
            if (std.mem.eql(u8, want.kind, "bitcoin") or std.mem.eql(u8, want.kind, "litecoin")) {
                const hit_msg = hit.msg orelse {
                    std.debug.print("{s}: block attestation lacks its node message\n", .{v.id});
                    return error.CheckFailed;
                };
                try std.testing.expectEqualSlices(u8, &root, &hit_msg);
            }
        }
    }
}

test "ots: a wrong expected digest is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vectors = try loadVectors(allocator);
    const v = vectors.vectors[0];
    const proof = try hexToBytes(allocator, v.proof_hex);
    var bad_digest = try hexToBytes32(v.file_digest_hex);
    bad_digest[0] ^= 1;
    try std.testing.expectError(error.DigestMismatch, ots.verify(allocator, proof, &bad_digest));
}

test "ots: corruption suite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vectors = try loadVectors(allocator);
    for (vectors.vectors) |v| {
        const proof = try hexToBytes(allocator, v.proof_hex);
        const file_digest = try hexToBytes32(v.file_digest_hex);
        const magic_len: usize = ots.HeaderMagic.len;

        var bad = try allocator.dupe(u8, proof);
        bad[0] ^= 1;
        try std.testing.expectError(error.BadMagic, ots.verify(allocator, bad, &file_digest));

        bad = try allocator.dupe(u8, proof);
        bad[magic_len] = 2;
        try std.testing.expectError(error.BadVersion, ots.verify(allocator, bad, &file_digest));

        bad = try allocator.dupe(u8, proof);
        bad[magic_len + 1] = 0x02;
        try std.testing.expectError(error.BadHashOp, ots.verify(allocator, bad, &file_digest));

        bad = try allocator.dupe(u8, proof);
        bad[magic_len + 2] ^= 1;
        try std.testing.expectError(error.DigestMismatch, ots.verify(allocator, bad, &file_digest));

        try std.testing.expectError(error.Truncated, ots.verify(allocator, proof[0 .. proof.len - 1], &file_digest));

        const with_garbage = try allocator.alloc(u8, proof.len + 1);
        @memcpy(with_garbage[0..proof.len], proof);
        with_garbage[proof.len] = 0x00;
        try std.testing.expectError(error.TrailingGarbage, ots.verify(allocator, with_garbage, &file_digest));

        bad = try allocator.dupe(u8, proof);
        bad[magic_len + 2 + 32] = 0xF2;
        try std.testing.expectError(error.UnknownOp, ots.verify(allocator, bad, &file_digest));
    }
}

test "ots: synthetic proof verifies against the stamped digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr synthetic ots test document");
    const proof = try ots_util.syntheticProof(allocator, &digest, 12345);
    const verification = try ots.verify(allocator, proof, &digest);
    try std.testing.expectEqualSlices(u8, &digest, &verification.root);
    try std.testing.expectEqual(@as(usize, 1), verification.attestations.len);
    const hit = verification.attestations[0];
    try std.testing.expect(hit.attestation == .bitcoin);
    try std.testing.expectEqual(@as(u64, 12345), hit.attestation.bitcoin);
    // Leaf message is sha256 applied twice to the file digest.
    try std.testing.expectEqualSlices(u8, &sha256(&sha256(&digest)), &hit.msg.?);
}

test "ots: prepend/append chain reaches the attested message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr chain test document");
    const pre: []const u8 = "PREFIX";
    const suf: []const u8 = "SUFFIX";
    const vb_pre = try varbytes(allocator, pre);
    const vb_suf = try varbytes(allocator, suf);
    const att = try attestation(allocator, ots.BitcoinTag, try heightPayload(allocator, 777));
    const tree = try concat(allocator, &.{
        &[_]u8{ots.OpPrepend},
        vb_pre,
        &[_]u8{ots.OpAppend},
        vb_suf,
        &[_]u8{ots.OpSha256},
        try leaf(allocator, att),
    });
    const proof = try buildProof(allocator, &digest, tree);

    // Message flow: digest -> pre||digest -> pre||digest||suf -> sha256.
    var combined: [32 + 6 + 6]u8 = undefined;
    @memcpy(combined[0..6], pre);
    @memcpy(combined[6..38], &digest);
    @memcpy(combined[38..44], suf);
    const want_msg = sha256(&combined);

    const verification = try ots.verify(allocator, proof, &digest);
    try std.testing.expectEqual(@as(usize, 1), verification.attestations.len);
    const hit = verification.attestations[0];
    try std.testing.expect(hit.attestation == .bitcoin and hit.attestation.bitcoin == 777);
    try std.testing.expectEqualSlices(u8, &want_msg, &hit.msg.?);
}

test "ots: a node with two ops yields one attestation per branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr branch test document");
    const a: []const u8 = "AAA";
    const b: []const u8 = "BB";
    const vb_a = try varbytes(allocator, a);
    const vb_b = try varbytes(allocator, b);
    const att_a = try attestation(allocator, ots.BitcoinTag, try heightPayload(allocator, 111));
    const att_b = try attestation(allocator, ots.LitecoinTag, try heightPayload(allocator, 222));
    const tree = try concat(allocator, &.{
        &[_]u8{0xFF},
        &[_]u8{ots.OpAppend},
        vb_a,
        try leaf(allocator, att_a),
        &[_]u8{ots.OpAppend},
        vb_b,
        try leaf(allocator, att_b),
    });
    const proof = try buildProof(allocator, &digest, tree);

    const verification = try ots.verify(allocator, proof, &digest);
    try std.testing.expectEqual(@as(usize, 2), verification.attestations.len);
    // Branch messages are 35 and 34 bytes, so no 32-byte node message is
    // attached to either attestation.
    try std.testing.expect(verification.attestations[0].attestation == .bitcoin and
        verification.attestations[0].attestation.bitcoin == 111);
    try std.testing.expect(verification.attestations[1].attestation == .litecoin and
        verification.attestations[1].attestation.litecoin == 222);
    try std.testing.expect(verification.attestations[0].msg == null);
    try std.testing.expect(verification.attestations[1].msg == null);
}

test "ots: an unknown attestation is accepted and reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr unknown attestation test");
    const unknown_tag: [8]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
    const att = try attestation(allocator, unknown_tag, try heightPayload(allocator, 77));
    const tree = try leaf(allocator, att);
    const proof = try buildProof(allocator, &digest, tree);

    const verification = try ots.verify(allocator, proof, &digest);
    try std.testing.expectEqual(@as(usize, 1), verification.attestations.len);
    try std.testing.expect(verification.attestations[0].attestation == .unknown);
    try std.testing.expectEqualSlices(u8, &unknown_tag, &verification.attestations[0].attestation.unknown);
    // The node message here is the 32-byte file digest itself.
    try std.testing.expectEqualSlices(u8, &digest, &verification.attestations[0].msg.?);
}

test "ots: a pending attestation round-trips its calendar uri" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr pending attestation test");
    const uri: []const u8 = "2026-01-15/calendar.example.com:8080/ots";
    const uri_vb = try varbytes(allocator, uri);
    const att = try attestation(allocator, ots.PendingTag, uri_vb);
    const tree = try leaf(allocator, att);
    const proof = try buildProof(allocator, &digest, tree);

    const verification = try ots.verify(allocator, proof, &digest);
    try std.testing.expectEqual(@as(usize, 1), verification.attestations.len);
    const hit = verification.attestations[0];
    try std.testing.expect(hit.attestation == .pending);
    try std.testing.expectEqualStrings(uri, hit.attestation.pending);
}

test "ots: recursion limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr recursion limit test");
    const att = try attestation(allocator, ots.BitcoinTag, try heightPayload(allocator, 1));

    // The boundary: 256 nested sha256 ops verify, 257 do not.
    var tree_ok = try allocator.alloc(u8, ots.RecursionLimit + 1 + att.len);
    @memset(tree_ok[0..ots.RecursionLimit], ots.OpSha256);
    tree_ok[ots.RecursionLimit] = 0x00;
    @memcpy(tree_ok[ots.RecursionLimit + 1 ..], att);
    const proof_ok = try buildProof(allocator, &digest, tree_ok);
    _ = try ots.verify(allocator, proof_ok, &digest);

    var tree_bad = try allocator.alloc(u8, ots.RecursionLimit + 2 + att.len);
    @memset(tree_bad[0 .. ots.RecursionLimit + 1], ots.OpSha256);
    tree_bad[ots.RecursionLimit + 1] = 0x00;
    @memcpy(tree_bad[ots.RecursionLimit + 2 ..], att);
    const proof_bad = try buildProof(allocator, &digest, tree_bad);
    try std.testing.expectError(error.RecursionLimit, ots.verify(allocator, proof_bad, &digest));
}

test "ots: op argument limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr op arg limit test");
    const att = try attestation(allocator, ots.BitcoinTag, try heightPayload(allocator, 1));
    const leaf_bytes = try leaf(allocator, att);

    // Empty op argument.
    var tree = try allocator.alloc(u8, 3 + leaf_bytes.len);
    tree[0] = ots.OpAppend;
    tree[1] = 0x00; // varbytes length 0
    tree[2] = 0x00; // final entry marker
    @memcpy(tree[3..], leaf_bytes);
    try std.testing.expectError(
        error.OpArgEmpty,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );

    // Op argument over the 4096-byte cap.
    const big_arg = try allocator.alloc(u8, ots.MaxOpArgLen + 1);
    @memset(big_arg, 0x01);
    const vb_big = try varbytes(allocator, big_arg);
    tree = try allocator.alloc(u8, 1 + vb_big.len);
    tree[0] = ots.OpAppend;
    @memcpy(tree[1..], vb_big);
    try std.testing.expectError(
        error.OpArgTooLong,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );

    // 4096-byte argument: the message (32 + 4096) exceeds the 4096-byte
    // result cap.
    const arg_at_cap = try allocator.alloc(u8, ots.MaxOpArgLen);
    @memset(arg_at_cap, 0x02);
    const vb_cap = try varbytes(allocator, arg_at_cap);
    tree = try allocator.alloc(u8, 1 + vb_cap.len + leaf_bytes.len);
    tree[0] = ots.OpAppend;
    @memcpy(tree[1 .. 1 + vb_cap.len], vb_cap);
    @memcpy(tree[1 + vb_cap.len ..], leaf_bytes);
    try std.testing.expectError(
        error.ResultTooLong,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );
}

test "ots: attestation payload limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr attestation limit test");

    // Payload over the 8192-byte cap (unknown tag).
    const big_payload = try allocator.alloc(u8, ots.MaxAttestationPayloadLen + 1);
    @memset(big_payload, 0);
    const unknown_tag: [8]u8 = @splat(0xBB);
    const vb_big = try varbytes(allocator, big_payload);
    var tree = try allocator.alloc(u8, 1 + 8 + vb_big.len);
    tree[0] = 0x00;
    @memcpy(tree[1..9], &unknown_tag);
    @memcpy(tree[9..], vb_big);
    try std.testing.expectError(
        error.AttestationPayloadTooLong,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );

    // Bitcoin payload with a trailing byte.
    const height = try heightPayload(allocator, 586);
    const trailing: []const u8 = &.{0x00};
    var payload = try allocator.alloc(u8, height.len + 1);
    @memcpy(payload[0..height.len], height);
    @memcpy(payload[height.len..], trailing);
    tree = try concat(allocator, &.{
        try leaf(allocator, try attestation(allocator, ots.BitcoinTag, payload)),
    });
    try std.testing.expectError(
        error.BadAttestation,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );

    // Pending uri with a character outside the allowed charset.
    const bad_uri: []const u8 = "a b";
    tree = try concat(allocator, &.{
        try leaf(allocator, try attestation(allocator, ots.PendingTag, try varbytes(allocator, bad_uri))),
    });
    try std.testing.expectError(
        error.BadUri,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );

    // Pending uri over the 1000-byte cap.
    const long_uri = try allocator.alloc(u8, ots.MaxPendingUriLen + 1);
    @memset(long_uri, 'a');
    tree = try concat(allocator, &.{
        try leaf(allocator, try attestation(allocator, ots.PendingTag, try varbytes(allocator, long_uri))),
    });
    try std.testing.expectError(
        error.BadUri,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );
}

test "ots: a 10-byte varint is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr varint limit test");
    // Bitcoin attestation whose payload length varint is ten 0x80 bytes.
    var tree = try allocator.alloc(u8, 1 + 8 + 10);
    tree[0] = 0x00;
    @memcpy(tree[1..9], &ots.BitcoinTag);
    @memset(tree[9..19], 0x80);
    try std.testing.expectError(
        error.VaruintTooLong,
        ots.verify(allocator, try buildProof(allocator, &digest, tree), &digest),
    );
}

test "ots: a proof over the 1 MiB cap is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const digest = sha256("zephyr size limit test");
    const big = try allocator.alloc(u8, ots.MaxProofLen + 1);
    @memcpy(big[0..ots.HeaderMagic.len], ots.HeaderMagic);
    try std.testing.expectError(error.TooLarge, ots.verify(allocator, big, &digest));
}
