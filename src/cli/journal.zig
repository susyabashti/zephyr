//! The shared journal access layer for the CLI commands: resolving the
//! journal path (`--journal`, $ZEPHYR_HOME), opening it with its master key
//! resolved (spec/encryption.md sections 3.4–5), the verify-before-trust
//! gate, the wall clock, and a sealed segment's footer head (ots-stamp /
//! ots-export).

const std = @import("std");
const core = @import("zephyr_core");
const key = @import("zephyr_key");
const errors = @import("errors.zig");
const output = @import("output.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn resolveJournalPath(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) core.journal.OpenError![]const u8 {
    const raw = if (explicit) |p| p else blk: {
        if (environ_map.get("ZEPHYR_HOME")) |home| break :blk home;
        if (environ_map.get("HOME")) |home| break :blk try allocator.print("{s}/.local/share/zephyr", .{home});
        return error.JournalNotFound;
    };
    if (std.Io.Dir.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    return try allocator.print("{s}/{s}", .{ cwd, raw });
}

/// Opens the journal for reads with its master key resolved
/// (spec/encryption.md sections 3.4–5):
///
/// - meta file present: the key is loaded from the store the meta pins —
///   never probed. A missing, locked, or corrupt key is reported and the
///   open fails.
/// - no meta, segments present: the journal is a v1 journal — a
///   discontinued, unencrypted format (spec section 4). It is neither read
///   nor migrated; the open fails.
/// - no meta, no segments: a fresh journal gets its key and meta before its
///   first record, with a one-time dim TTY notice.
pub fn openReadJournal(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    create_if_missing: bool,
) errors.RunError!core.journal.Journal {
    var journal = core.journal.Journal.open(arena, io, environ_map, path, create_if_missing) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try output.printLine(err_file, io, try arena.print(
                "{s}journal not found: {s}",
                .{ try style.errMark(arena), try style.dim(arena, path) },
            ));
            return error.JournalNotFound;
        },
        else => return err,
    };
    const meta = try journal.loadMeta(arena);
    if (meta) |m| {
        const key_bytes = key.resolve.load(io, journal.dir, &m) catch |err| return mapKeyLoadError(err_file, io, style, arena, err);
        journal.key = key_bytes;
        return journal;
    }
    const names = try journal.listSegments(arena);
    defer {
        for (names) |name| arena.free(name);
        arena.free(names);
    }
    if (names.len == 0) {
        const created = key.resolve.create(io, journal.dir) catch |err| return mapKeyCreateError(err_file, io, style, arena, err);
        try writeKeyMeta(&journal, arena, created.store);
        journal.key = created.key;
        try notifyKey(style, err_file, io, arena, try arena.print(
            "created an encrypted journal (key: {s})",
            .{storeLabel(created.store)},
        ));
        return journal;
    }
    // Segments without a meta file: a v1 journal. v1 is discontinued
    // (spec/encryption.md section 4) — it is neither read nor migrated.
    try output.printLine(err_file, io, try arena.print(
        "{s}journal {s} was written by a discontinued version of zephyr (unencrypted); v1 journals are no longer supported",
        .{ try style.errMark(arena), try style.dim(arena, path) },
    ));
    return error.UnsupportedJournal;
}

/// The one-time dim TTY notice (stderr): pipes stay clean.
fn notifyKey(style: output.Style, err_file: File, io: Io, arena: Allocator, message: []const u8) errors.RunError!void {
    if (!style.enabled) return;
    return output.printLine(err_file, io, try style.dim(arena, message));
}

fn storeLabel(store: core.vault.Store) []const u8 {
    return switch (store) {
        .keychain => "macOS Keychain",
        .keyfile => "key file",
    };
}

fn keyIdFor(store: core.vault.Store) []const u8 {
    return switch (store) {
        .keychain => core.vault.KeychainMasterAccount,
        .keyfile => core.vault.KeyFileName,
    };
}

fn writeKeyMeta(journal: *const core.journal.Journal, allocator: Allocator, store: core.vault.Store) errors.RunError!void {
    const meta = core.vault.Meta{ .store = store, .key_id = keyIdFor(store) };
    return journal.writeMeta(allocator, &meta);
}

/// Maps a key load failure to the CLI's exit-1 errors, with a message.
fn mapKeyLoadError(err_file: File, io: Io, style: output.Style, arena: Allocator, err: key.resolve.LoadError) errors.RunError {
    return switch (err) {
        error.KeyNotFound => {
            try output.printLine(err_file, io, try arena.print(
                "{s}the journal's key is missing — restore it to read this journal",
                .{try style.errMark(arena)},
            ));
            return error.KeyNotFound;
        },
        error.Unavailable => {
            try output.printLine(err_file, io, try arena.print(
                "{s}the macOS keychain is locked or unavailable",
                .{try style.errMark(arena)},
            ));
            return error.KeychainUnavailable;
        },
        error.BadKeyFile, error.BadItem => {
            try output.printLine(err_file, io, try arena.print(
                "{s}the journal's key is corrupt",
                .{try style.errMark(arena)},
            ));
            return error.KeyCorrupt;
        },
        else => return err,
    };
}

/// Maps a key creation failure to the CLI's exit-1 errors.
fn mapKeyCreateError(err_file: File, io: Io, style: output.Style, arena: Allocator, err: key.resolve.CreateError) errors.RunError {
    return switch (err) {
        // The key file appeared between the load and the create — it exists
        // but is not a valid key.
        error.AlreadyExists => {
            try output.printLine(err_file, io, try arena.print(
                "{s}the journal's key is corrupt",
                .{try style.errMark(arena)},
            ));
            return error.KeyCorrupt;
        },
        else => return err,
    };
}

pub fn verifyOrReport(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    journal: *const core.journal.Journal,
) errors.RunError!core.journal.VerifyResult {
    const result = try journal.verify(arena);
    if (!result.ok) {
        try output.reportIssue(err_file, io, style, arena, result.issue.?);
        return error.VerifyFailed;
    }
    return result;
}

/// The sealed segment's 32-byte footer head (shared by ots-stamp and
/// ots-export). An unsealed segment is reported and becomes SegmentNotSealed.
pub fn sealedSegmentHead(
    arena: Allocator,
    io: Io,
    style: output.Style,
    err_file: File,
    journal: *const core.journal.Journal,
    seg_name: []const u8,
) errors.RunError![32]u8 {
    const seg_bytes = try journal.readSegment(arena, seg_name);
    return core.segment.footerHead(seg_bytes) catch |err| switch (err) {
        error.NotSealed => {
            try output.printLine(err_file, io, try arena.print(
                "{s}segment {s} is not sealed",
                .{ try style.errMark(arena), seg_name },
            ));
            return error.SegmentNotSealed;
        },
        else => |e| return e,
    };
}

pub fn nowMs(io: Io) u64 {
    const ms = Io.Timestamp.now(io, .real).toMilliseconds();
    if (ms < 0) std.debug.panic("wall clock is before the Unix epoch", .{});
    return @intCast(ms);
}
