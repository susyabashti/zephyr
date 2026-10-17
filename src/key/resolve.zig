//! Key resolution (spec/encryption.md section 3.4): the store is chosen
//! once, at key creation — macOS prefers the keychain and falls back to
//! the key file when it is unavailable — and pinned in the journal's meta
//! file. The meta is the sole address of a journal's key: it is never
//! probed.

const std = @import("std");
const vault = @import("zephyr_core").vault;
const keyfile = @import("keyfile.zig");
const keychain = @import("keychain.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// A freshly created key and the store that holds it.
pub const Created = struct {
    key: [vault.KeyLen]u8,
    store: vault.Store,
};

pub const CreateError = keyfile.Error || keychain.Error;
pub const LoadError = keyfile.Error || keychain.Error;

/// Creates the master key and stores it. The returned key is what the
/// caller seals the first payloads with; the meta file (written after the
/// segments) pins the store.
///
/// macOS prefers the keychain (spec section 3.4), but a keychain create is
/// trusted only when the key can be read back: a store that reports success
/// yet cannot be loaded is unavailable, and the key file takes over — the
/// journal must never be sealed with a key that exists nowhere. When an
/// item with the known identity already exists, the stored key is adopted,
/// never shadowed by the fresh one.
pub fn create(io: Io, journal_dir: Dir) CreateError!Created {
    if (keychain.isSupported) {
        var key: [vault.KeyLen]u8 = undefined;
        try Io.randomSecure(io, &key);
        keychain.create(vault.KeychainMasterAccount, &key) catch |err| switch (err) {
            // The data-protection keychain refused the item (some macOS
            // releases require entitlements a CLI binary lacks, or the
            // store is locked or absent): the key file takes over
            // (spec section 3.4). The fresh key is discarded — it was
            // never stored.
            error.Unavailable => {
                const keyfile_key = keyfile.create(journal_dir, io) catch return err;
                return .{ .key = keyfile_key, .store = .keyfile };
            },
            else => return err,
        };
        // Verify the key actually landed: read it back. A create that
        // cannot be confirmed is a data-loss path, never a success.
        const stored = keychain.load(vault.KeychainMasterAccount) catch |err| switch (err) {
            error.KeyNotFound, error.Unavailable => {
                const keyfile_key = keyfile.create(journal_dir, io) catch return err;
                return .{ .key = keyfile_key, .store = .keyfile };
            },
            else => return err,
        };
        // errSecDuplicateItem: an item with this identity pre-existed (one
        // master key per machine, spec section 1). The stored key is the
        // machine's key — adopt it, never shadow it with the fresh one.
        if (!std.mem.eql(u8, &stored, &key)) {
            return .{ .key = stored, .store = .keychain };
        }
        return .{ .key = key, .store = .keychain };
    }
    const key = try keyfile.create(journal_dir, io);
    return .{ .key = key, .store = .keyfile };
}

/// Loads the master key pinned by the journal's meta file — the only load
/// path for a journal that has a meta.
pub fn load(io: Io, journal_dir: Dir, meta: *const vault.Meta) LoadError![vault.KeyLen]u8 {
    return switch (meta.store) {
        .keychain => keychain.load(meta.key_id),
        .keyfile => keyfile.load(journal_dir, io),
    };
}

/// The `key status` rendering: where the key lives.
pub fn storeDescription(meta: *const vault.Meta) []const u8 {
    return switch (meta.store) {
        .keychain => "macOS Keychain",
        .keyfile => "key file (0600)",
    };
}
