//! The macOS keychain store (spec/encryption.md section 3.3): the 32-byte
//! master key as a generic-password item in the data-protection keychain,
//! accessibility WhenUnlockedThisDeviceOnly — the key never leaves the
//! device, even in backups.
//!
//! The extern surface is hand-written and verified against the macOS SDK
//! (Security.framework's SecItem.h, CoreFoundation) with `zig translate-c`.
//! All CF object references collapse to one nullable pointer type; the
//! opaque object layouts are irrelevant (only pointers cross the boundary).
//! Key ids are short ASCII (enforced by `vault.decodeMeta`), so C strings
//! are built on the stack.
//!
//! The extern declarations compile on every platform (they are inert until
//! referenced); off macOS the public entry points report `Unavailable`
//! before any of it is called, and resolve falls back to the key file.

const std = @import("std");
const builtin = @import("builtin");
const vault = @import("zephyr_core").vault;
const assert = std.debug.assert;

pub const Error = error{
    /// The keychain has no item with this key id.
    KeyNotFound,
    /// The keychain is locked, unavailable, or refused the operation.
    Unavailable,
    /// The stored item is not exactly 32 bytes.
    BadItem,
};

/// Whether this platform has a keychain store at all.
pub const isSupported: bool = builtin.target.os.tag == .macos;

/// Stores the master key as a keychain item with the given key id.
/// `errSecDuplicateItem` (an item with the same identity already exists) is
/// treated as success: the caller then loads the existing key.
pub fn create(key_id: []const u8, key: *const [vault.KeyLen]u8) Error!void {
    if (!isSupported) return error.Unavailable;
    return createMacos(key_id, key);
}

/// Loads the 32-byte master key stored under the given key id.
pub fn load(key_id: []const u8) Error![vault.KeyLen]u8 {
    if (!isSupported) return error.Unavailable;
    return loadMacos(key_id);
}

// ------------------------------------------------------------- externs
const CFTypeRef = ?*const anyopaque; // every CF object reference
const CFIndex = i64; // c_long
const OSStatus = i32; // SInt32

const CbKey = extern struct {
    version: CFIndex,
    retain: ?*const fn (alloc: CFTypeRef, value: ?*const anyopaque) callconv(.c) ?*const anyopaque,
    release: ?*const fn (alloc: CFTypeRef, value: ?*const anyopaque) callconv(.c) void,
    copy_description: ?*const fn (value: ?*const anyopaque) callconv(.c) CFTypeRef,
    equal: ?*const fn (a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) u8,
    hash: ?*const fn (value: ?*const anyopaque) callconv(.c) u32,
};
const CbValue = extern struct {
    version: CFIndex,
    retain: ?*const fn (alloc: CFTypeRef, value: ?*const anyopaque) callconv(.c) ?*const anyopaque,
    release: ?*const fn (alloc: CFTypeRef, value: ?*const anyopaque) callconv(.c) void,
    copy_description: ?*const fn (value: ?*const anyopaque) callconv(.c) CFTypeRef,
    equal: ?*const fn (a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) u8,
};

extern fn CFStringCreateWithCString(alloc: CFTypeRef, cstr: [*c]const u8, encoding: u32) CFTypeRef;
extern fn CFDataCreate(alloc: CFTypeRef, bytes: [*c]const u8, length: CFIndex) CFTypeRef;
extern fn CFDataGetLength(data: CFTypeRef) CFIndex;
extern fn CFDataGetBytePtr(data: CFTypeRef) [*c]const u8;
extern fn CFDictionaryCreate(
    alloc: CFTypeRef,
    keys: [*c]const ?*const anyopaque,
    values: [*c]const ?*const anyopaque,
    num_values: CFIndex,
    key_cb: [*c]const CbKey,
    value_cb: [*c]const CbValue,
) CFTypeRef;
extern fn CFRelease(cf: CFTypeRef) void;
extern fn SecItemAdd(attributes: CFTypeRef, result: [*c]CFTypeRef) OSStatus;
extern fn SecItemCopyMatching(query: CFTypeRef, result: [*c]CFTypeRef) OSStatus;

// CoreFoundation / Security globals (SecItem.h, CFDictionary.h).
extern const kCFBooleanTrue: CFTypeRef;
extern const kCFTypeDictionaryKeyCallBacks: CbKey;
extern const kCFTypeDictionaryValueCallBacks: CbValue;
extern const kSecClass: CFTypeRef;
extern const kSecClassGenericPassword: CFTypeRef;
extern const kSecAttrService: CFTypeRef;
extern const kSecAttrAccount: CFTypeRef;
extern const kSecAttrAccessible: CFTypeRef;
extern const kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFTypeRef;
extern const kSecValueData: CFTypeRef;
extern const kSecReturnData: CFTypeRef;
// macOS 10.15+: address the data-protection keychain (the store that
// honours kSecAttrAccessible from command-line tools).
extern const kSecUseDataProtectionKeychain: CFTypeRef;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const errSecSuccess: OSStatus = 0;
const errSecDuplicateItem: OSStatus = -25299;
const errSecItemNotFound: OSStatus = -25300;

// ------------------------------------------------------- implementation
/// A service name or key id (short ASCII, validated by vault.decodeMeta):
/// the C string is built on the stack.
fn cfStringBuf(name: []const u8, buf: *[256]u8) CFTypeRef {
    assert(name.len < buf.len);
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return CFStringCreateWithCString(null, buf.ptr, kCFStringEncodingUTF8);
}

fn createMacos(key_id: []const u8, key: *const [vault.KeyLen]u8) Error!void {
    var service_buf: [256]u8 = undefined;
    const service = cfStringBuf(vault.KeychainService, &service_buf) orelse return error.Unavailable;
    var account_buf: [256]u8 = undefined;
    const account = cfStringBuf(key_id, &account_buf) orelse {
        CFRelease(service);
        return error.Unavailable;
    };
    const data = CFDataCreate(null, key.ptr, @intCast(key.len)) orelse {
        CFRelease(account);
        CFRelease(service);
        return error.Unavailable;
    };
    defer {
        CFRelease(data);
        CFRelease(account);
        CFRelease(service);
    }

    const keys: [6]CFTypeRef = .{
        kSecClass,
        kSecAttrService,
        kSecAttrAccount,
        kSecValueData,
        kSecAttrAccessible,
        kSecUseDataProtectionKeychain,
    };
    const values: [6]CFTypeRef = .{
        kSecClassGenericPassword,
        service,
        account,
        data,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kCFBooleanTrue,
    };
    const dict = CFDictionaryCreate(null, &keys, &values, 6, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse
        return error.Unavailable;
    defer CFRelease(dict);

    // SecItemAdd returns no item reference; pass NULL.
    const status = SecItemAdd(dict, @as([*c]?*const anyopaque, null));
    switch (status) {
        // errSecDuplicateItem: an item with the same identity exists —
        // the caller loads the existing key.
        errSecSuccess, errSecDuplicateItem => return,
        else => return error.Unavailable,
    }
}

fn loadMacos(key_id: []const u8) Error![vault.KeyLen]u8 {
    var service_buf: [256]u8 = undefined;
    const service = cfStringBuf(vault.KeychainService, &service_buf) orelse return error.Unavailable;
    var account_buf: [256]u8 = undefined;
    const account = cfStringBuf(key_id, &account_buf) orelse {
        CFRelease(service);
        return error.Unavailable;
    };
    defer {
        CFRelease(account);
        CFRelease(service);
    }

    const keys: [5]CFTypeRef = .{ kSecClass, kSecAttrService, kSecAttrAccount, kSecUseDataProtectionKeychain, kSecReturnData };
    const values: [5]CFTypeRef = .{ kSecClassGenericPassword, service, account, kCFBooleanTrue, kCFBooleanTrue };
    const query = CFDictionaryCreate(null, &keys, &values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse
        return error.Unavailable;
    defer CFRelease(query);

    var result: CFTypeRef = null;
    const status = SecItemCopyMatching(query, &result);
    switch (status) {
        errSecSuccess => {
            const data = result orelse return error.Unavailable;
            const len: usize = @intCast(CFDataGetLength(data));
            if (len != vault.KeyLen) return error.BadItem;
            var key: [vault.KeyLen]u8 = undefined;
            @memcpy(&key, CFDataGetBytePtr(data)[0..len]);
            return key;
        },
        errSecItemNotFound => return error.KeyNotFound,
        else => return error.Unavailable,
    }
}
