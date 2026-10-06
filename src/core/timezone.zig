//! Local timezone offset for record headers (spec section 3: tz_offset_min).
//!
//! Resolves the system tz file (TZ env var, else /etc/localtime) and parses it
//! with std.tz. Practical zones have whole-minute offsets; fractional-minute
//! offsets (historical only) are rejected with a clear error.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub const Tz = std.tz.Tz;

pub const ResolveError = Allocator.Error;

pub const LoadError = error{
    TzFileNotFound,
    BadTzFile,
    FractionalMinuteOffset,
    EndOfStream,
    ReadFailed,
    StreamTooLong,
    BadVersion,
    BadHeader,
    Malformed,
    OverlargeFooter,
} || Io.File.OpenError || Allocator.Error;

/// Resolves the tz data file path per POSIX convention: a non-empty TZ env var
/// wins (a value containing '/' is a file path, else a zone name under
/// /usr/share/zoneinfo), else /etc/localtime.
pub fn resolveTzFile(allocator: Allocator, environ_map: *const std.process.Environ.Map) ResolveError![]const u8 {
    if (environ_map.get("TZ")) |tz| {
        if (tz.len == 0) return defaultTzFile(allocator);
        if (std.mem.indexOfScalar(u8, tz, '/')) |_| {
            return allocator.dupe(u8, tz);
        }
        return allocator.print("/usr/share/zoneinfo/{s}", .{tz});
    }
    return defaultTzFile(allocator);
}

fn defaultTzFile(allocator: Allocator) Allocator.Error![]const u8 {
    return allocator.dupe(u8, "/etc/localtime");
}

/// Loads and parses the tz file. The result is owned by `allocator`.
pub fn load(allocator: Allocator, io: Io, tz_file: []const u8) LoadError!*Tz {
    const file = try Dir.openFileAbsolute(io, tz_file, .{ .mode = .read_only });
    defer File.close(file, io);
    var buffer: [65536]u8 = undefined;
    var file_reader = File.Reader.init(file, io, &buffer);
    const ptr = try allocator.create(Tz);
    errdefer allocator.destroy(ptr);
    ptr.* = try Tz.parse(allocator, &file_reader.interface);
    return ptr;
}

/// Offset in whole minutes at Unix time `ts_seconds`.
pub fn offsetMinutesAt(tz: *const Tz, ts_seconds: i64) LoadError!i32 {
    const transitions = tz.transitions;
    // Per TZif, times before the first transition use timetype 0.
    var index: usize = 0;
    if (transitions.len > 0 and transitions[0].ts <= ts_seconds) {
        // Find the last transition with ts <= ts_seconds (transitions ascend).
        var lo: usize = 0;
        var hi: usize = transitions.len;
        while (lo < hi) {
            const mid = @divFloor(lo + hi, 2);
            if (transitions[mid].ts <= ts_seconds) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        index = lo - 1;
    }
    const timetype: *const std.tz.Timetype = if (transitions.len > 0 and transitions[0].ts <= ts_seconds)
        transitions[index].timetype
    else
        &tz.timetypes[0];
    const offset = timetype.offset;
    if (@rem(offset, 60) != 0) return error.FractionalMinuteOffset;
    return @intCast(@divTrunc(offset, 60));
}
