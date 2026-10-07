//! Phase 5 vector suite: the anchor byte contract.
//!
//! spec/vectors/anchors.json pins RFC 8032 section 2.10 known-answer pairs
//! (which validate the Ed25519 implementation) and full 190-byte anchor
//! artifacts for fixed (seed, head, count, timestamp_ms, checkpoint_seq)
//! inputs (which validate the artifact construction and the
//! self-verification path). This file re-derives everything from the inputs
//! with std.crypto Ed25519 and the core anchor module, so it fails if any of
//! them drifts from the frozen format. The independent Python reference
//! (test/reference.py, with its own pure-Python Ed25519) checks the same
//! file.

const std = @import("std");
const options = @import("std_options");
const core = @import("zephyr_core");

const anchor = core.anchor;
const records = core.records;
const Ed25519 = std.crypto.sign.Ed25519;

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- schema

const Vectors = struct {
    format_version: u32,
    ed25519_known_answer: []KnownAnswer,
    anchors: []AnchorInput,
};

const KnownAnswer = struct {
    id: []const u8,
    seed_hex: []const u8,
    message_hex: []const u8,
    public_key_hex: []const u8,
    signature_hex: []const u8,
};

const AnchorInput = struct {
    id: []const u8,
    description: ?[]const u8,
    seed_hex: []const u8,
    head_hex: []const u8,
    count: u64,
    timestamp_ms: u64,
    checkpoint_seq: u64,
    expect: AnchorExpect,
};

const AnchorExpect = struct {
    public_key_hex: []const u8,
    signature_hex: []const u8,
    artifact_hex: []const u8,
};

// ---------------------------------------------------------------- load

fn loadVectors(allocator: Allocator) anyerror!Vectors {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.anchors, allocator, .unlimited);
    return std.json.parseFromSliceLeaky(Vectors, allocator, bytes, .{});
}

// ---------------------------------------------------------------- checks

const CheckError = Allocator.Error || anchor.VerifyError || anchor.SignError || error{
    HexLength,
    HexDigit,
    KeyGeneration,
    NonCanonicalKey,
    SignatureInvalid,
};

test "anchors: RFC 8032 known answers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vectors = try loadVectors(allocator);
    try std.testing.expectEqual(@as(u32, 1), vectors.format_version);
    try std.testing.expect(vectors.ed25519_known_answer.len >= 3);

    for (vectors.ed25519_known_answer) |ka| {
        var seed: [32]u8 = undefined;
        decodeHex(&seed, ka.seed_hex) catch return error.HexLength;
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch |err| switch (err) {
            error.IdentityElement => return error.KeyGeneration,
        };

        var expected_pub: [32]u8 = undefined;
        decodeHex(&expected_pub, ka.public_key_hex) catch return error.HexLength;
        if (!std.mem.eql(u8, &expected_pub, &kp.public_key.toBytes())) {
            std.debug.print("{s}: derived public key differs from the RFC vector\n", .{ka.id});
            return error.NonCanonicalKey;
        }

        const message = try hexSlice(allocator, ka.message_hex);
        const sig = try kp.sign(message, null);
        var expected_sig: [64]u8 = undefined;
        decodeHex(&expected_sig, ka.signature_hex) catch return error.HexLength;
        if (!std.mem.eql(u8, &expected_sig, &sig.toBytes())) {
            std.debug.print("{s}: derived signature differs from the RFC vector\n", .{ka.id});
            return error.SignatureInvalid;
        }

        // The pinned signature must also verify under the pinned key.
        const pub_key = Ed25519.PublicKey.fromBytes(expected_pub) catch return error.NonCanonicalKey;
        sig.verify(message, pub_key) catch return error.SignatureInvalid;
    }
}

test "anchors: pinned 190-byte artifacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vectors = try loadVectors(allocator);
    try std.testing.expect(vectors.anchors.len >= 2);

    for (vectors.anchors) |a| {
        var seed: [32]u8 = undefined;
        decodeHex(&seed, a.seed_hex) catch return error.HexLength;
        var head: [32]u8 = undefined;
        decodeHex(&head, a.head_hex) catch return error.HexLength;
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch |err| switch (err) {
            error.IdentityElement => return error.KeyGeneration,
        };

        var expected_pub: [32]u8 = undefined;
        decodeHex(&expected_pub, a.expect.public_key_hex) catch return error.HexLength;
        if (!std.mem.eql(u8, &expected_pub, &kp.public_key.toBytes())) {
            std.debug.print("{s}: derived public key differs from the pinned vector\n", .{a.id});
            return error.NonCanonicalKey;
        }

        // The full artifact, byte for byte.
        const bytes = try anchor.render(&kp, head, a.count, a.timestamp_ms, a.checkpoint_seq);
        const expected = try allocator.alloc(u8, a.expect.artifact_hex.len / 2);
        defer allocator.free(expected);
        decodeHex(expected, a.expect.artifact_hex) catch return error.HexLength;
        if (!std.mem.eql(u8, expected, &bytes)) {
            std.debug.print("{s}: derived artifact differs from the pinned vector\n", .{a.id});
            return error.HexLength;
        }

        // The pinned signature is the artifact's signature field.
        var expected_sig: [64]u8 = undefined;
        decodeHex(&expected_sig, a.expect.signature_hex) catch return error.HexLength;
        var sig_field: [64]u8 = undefined;
        @memcpy(&sig_field, bytes[94..158]);
        if (!std.mem.eql(u8, &expected_sig, &sig_field)) {
            std.debug.print("{s}: pinned signature differs from the artifact's signature field\n", .{a.id});
            return error.HexLength;
        }

        // Self-verification passes and round-trips the inputs.
        const artifact = anchor.verifyBytes(&bytes) catch |err| {
            std.debug.print("{s}: self-verification failed: {s}\n", .{ a.id, @errorName(err) });
            return err;
        };
        try std.testing.expectEqual(a.count, artifact.count);
        try std.testing.expectEqual(a.timestamp_ms, artifact.timestamp_ms);
        try std.testing.expectEqual(a.checkpoint_seq, artifact.checkpoint_seq);
        try std.testing.expectEqualSlices(u8, &head, &artifact.head);
    }
}

test "anchors: corruption is detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vectors = try loadVectors(allocator);
    const a = vectors.anchors[0];
    var seed: [32]u8 = undefined;
    decodeHex(&seed, a.seed_hex) catch return error.HexLength;
    var head: [32]u8 = undefined;
    decodeHex(&head, a.head_hex) catch return error.HexLength;
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch |err| switch (err) {
        error.IdentityElement => return error.KeyGeneration,
    };
    const bytes = try anchor.render(&kp, head, a.count, a.timestamp_ms, a.checkpoint_seq);

    // A flipped signature byte: the hash covers the signature, so this is a
    // hash failure, not a signature failure.
    var bad = try allocator.dupe(u8, &bytes);
    defer allocator.free(bad);
    bad[100] ^= 1;
    try std.testing.expectError(error.BadHash, anchor.verifyBytes(bad));

    // Flipping the signature AND recomputing the hash exercises the
    // signature check itself.
    bad[100] ^= 1; // restore
    bad[120] ^= 1;
    var digest: [32]u8 = undefined;
    records.Sha256.hash(bad[0..anchor.HashedLen], &digest, .{});
    @memcpy(bad[anchor.HashedLen..], &digest);
    try std.testing.expectError(error.SignatureVerificationFailed, anchor.verifyBytes(bad));

    // A flipped head byte (hash intact) is again caught by the hash.
    bad = try allocator.dupe(u8, &bytes);
    defer allocator.free(bad);
    bad[40] ^= 1;
    try std.testing.expectError(error.BadHash, anchor.verifyBytes(bad));

    // Well-formedness failures.
    try std.testing.expectError(error.BadLength, anchor.verifyBytes(bad[0 .. bad.len - 1]));
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, anchor.verifyBytes(bad));
}

// ---------------------------------------------------------------- hex

fn hexSlice(allocator: Allocator, hex: []const u8) CheckError![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    decodeHex(out, hex) catch return error.HexLength;
    return out;
}

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
