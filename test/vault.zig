//! Encryption gates (spec/encryption.md): verify with the key, the
//! plaintext round trip, and LLM-view invariance between a v1 and a v2
//! journal carrying the same records. All timestamps are pinned.
//!
//! v1 is discontinued (spec section 4): journals are born encrypted, so the
//! v2 journal here is built the way the CLI builds a fresh one — key set
//! before the first append, meta written with it. The v1 twin exists only
//! in-process (key null), the shape the vector harness builds.
//!
//! Regression context: `collectPlaintext` once read the decrypted body
//! after freeing it — 0.17's free poisons the released region, so every v2
//! read produced poison-byte "plaintext" and the view layer hung on the
//! resulting garbage. These gates pin the round trip end to end.

const std = @import("std");
const core = @import("zephyr_core");

const records = core.records;
const vault = core.vault;
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const TZ: i16 = 120;

/// A fixed master key: the gates must be deterministic.
fn testKey() [vault.KeyLen]u8 {
    var key: [vault.KeyLen]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i + 1);
    return key;
}

fn openFixture(io: Io, allocator: Allocator, name: []const u8) !core.journal.Journal {
    const cwd = Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/{s}", .{ cwd_path, name });
    const environ = std.process.Environ.Map.init(allocator);
    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    return try core.journal.Journal.open(allocator, io, &environ, path, true);
}

fn closeFixture(io: Io, allocator: Allocator, name: []const u8, journal: core.journal.Journal) void {
    journal.close();
    const cwd = Dir.cwd();
    const cwd_path = std.process.currentPathAlloc(io, allocator) catch return;
    defer allocator.free(cwd_path);
    const path = allocator.print("{s}/{s}", .{ cwd_path, name }) catch return;
    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
}

test "vault: born-encrypted round trip, verify, view invariance" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // The v1 twin: the same records with no key (the vector harness shape),
    // so the rendered view can be compared byte for byte against the
    // encrypted journal's.
    var v1 = try openFixture(io, allocator, ".tmp-vault-a");
    defer closeFixture(io, allocator, ".tmp-vault-a", v1);
    const work = [_][]const u8{"work"};
    _ = try v1.appendRecord(allocator, .entry, 0, "morning run in the rain", &work, 1_768_520_700_000, TZ, false);
    _ = try v1.appendRecord(allocator, .entry, 0, "quiet day, mostly reading", &.{}, 1_768_559_400_000, TZ, false);
    _ = try v1.appendRecord(allocator, .entry, 0, "a plan that never was", &.{}, 1_768_595_400_000, TZ, false);
    _ = try v1.redact(allocator, 2, 1_768_631_400_000, TZ);

    const recs_v1 = try v1.collectRecords(allocator);
    defer recs_v1.deinit();
    const view_v1 = try core.view.render(allocator, recs_v1.headers, recs_v1.payloads);
    defer allocator.free(view_v1);

    // The v2 journal: born encrypted — key set before the first append and
    // the meta written alongside, as the CLI's open flow does for a fresh
    // journal (spec section 4).
    var v2 = try openFixture(io, allocator, ".tmp-vault-b");
    defer closeFixture(io, allocator, ".tmp-vault-b", v2);
    const key = testKey();
    v2.key = key;
    try v2.writeMeta(allocator, &.{ .store = .keyfile, .key_id = vault.KeyFileName });
    _ = try v2.appendRecord(allocator, .entry, 0, "morning run in the rain", &work, 1_768_520_700_000, TZ, false);
    _ = try v2.appendRecord(allocator, .entry, 0, "quiet day, mostly reading", &.{}, 1_768_559_400_000, TZ, false);
    _ = try v2.appendRecord(allocator, .entry, 0, "a plan that never was", &.{}, 1_768_595_400_000, TZ, false);
    _ = try v2.redact(allocator, 2, 1_768_631_400_000, TZ);

    // The meta file pins the store (spec section 3).
    const meta = (try v2.loadMeta(allocator)).?;
    try std.testing.expectEqual(@as(vault.Store, .keyfile), meta.store);
    try std.testing.expectEqualStrings(vault.KeyFileName, meta.key_id);

    // Verify with the key: pass 2 authenticates and decodes every payload.
    const ok = try v2.verify(allocator);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqual(@as(u64, 4), ok.record_count);
    try std.testing.expectEqual(@as(u64, 1), ok.redacted_count);
    try std.testing.expect(!ok.payloads_unverified);

    // Plaintext round trip: the decrypted payloads must decode to exactly
    // what was written. This is the canary for reading the body after
    // freeing it — a poison-read produces 0xAA (debug) or 0x00 (release)
    // text here.
    const recs_v2 = try v2.collectPlaintext(allocator);
    defer recs_v2.deinit();
    try std.testing.expectEqual(@as(usize, 4), recs_v2.payloads.len);
    const d0 = try records.decodePayload(allocator, recs_v2.payloads[0]);
    defer allocator.free(d0.tags);
    try std.testing.expectEqualStrings("morning run in the rain", d0.text);
    try std.testing.expectEqual(@as(usize, 1), d0.tags.len);
    try std.testing.expectEqualStrings("work", d0.tags[0]);
    const d1 = try records.decodePayload(allocator, recs_v2.payloads[1]);
    defer allocator.free(d1.tags);
    try std.testing.expectEqualStrings("quiet day, mostly reading", d1.text);
    // The redacted entry's plaintext form carries the v1 placeholder bytes.
    try std.testing.expect(records.isRedactedPlaceholder(recs_v2.payloads[2]));

    // The LLM view is a pure function of the records: encrypting the journal
    // must not change a single rendered byte.
    const view_v2 = try core.view.render(allocator, recs_v2.headers, recs_v2.payloads);
    defer allocator.free(view_v2);
    try std.testing.expectEqualSlices(u8, view_v1, view_v2);
}

test "vault: envelope bytes agree with the independent Python reference" {
    // test/vaultref.py sealed these exact inputs (master = 1..32, nonce =
    // 0..23, aad = 0..28, plaintext = "hello vault"). Two implementations
    // working only from spec/encryption.md section 2 must match.
    const allocator = std.testing.allocator;
    var master: [vault.KeyLen]u8 = undefined;
    for (&master, 0..) |*b, i| b.* = @intCast(i + 1);
    var nonce: [vault.NonceLen]u8 = undefined;
    for (&nonce, 0..) |*b, i| b.* = @intCast(i);
    var aad: [vault.AadLen]u8 = undefined;
    for (&aad, 0..) |*b, i| b.* = @intCast(i);
    const envelope = try vault.seal(allocator, &master, nonce, &aad, "hello vault");
    defer allocator.free(envelope);
    const want = "02000102030405060708090a0b0c0d0e0f1011121314151617" ++
        "fb6a0703648f38227e2ea38c88ef9bfb40ee1546209f74af3b6676";
    var decoded: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(&decoded, want);
    try std.testing.expectEqualSlices(u8, &decoded, envelope);
    const opened = try vault.open(allocator, &master, &aad, envelope);
    defer allocator.free(opened);
    try std.testing.expectEqualStrings("hello vault", opened);
}
