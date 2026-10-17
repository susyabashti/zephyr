//! Key module (spec/encryption.md): where the journal's master key lives.
//! `core.vault` defines the envelope format; this module chooses and
//! operates the stores — the macOS keychain (section 3.3) and the 0600
//! key file (section 3.2) — plus the resolution rules (section 3.4).

pub const keyfile = @import("key/keyfile.zig");
pub const keychain = @import("key/keychain.zig");
pub const resolve = @import("key/resolve.zig");
