//! Argument and flag parsing shared by the CLI commands: the `-t TAG`
//! flags plus free text, civil-date and date-range parsing, the current
//! week under the journal's timezone, and environment command specs
//! ($PAGER, $VISUAL/$EDITOR) split into argv.

const std = @import("std");
const core = @import("zephyr_core");
const errors = @import("errors.zig");
const cli_journal = @import("journal.zig");

const Allocator = std.mem.Allocator;

pub const ParsedArgs = struct {
    tags: std.ArrayList([]const u8),
    parts: std.ArrayList([]const u8),

    pub fn deinit(self: *ParsedArgs, allocator: Allocator) void {
        self.tags.deinit(allocator);
        self.parts.deinit(allocator);
    }
};

/// A command spec taken from the environment ($PAGER, $VISUAL, $EDITOR):
/// whitespace-split into at most 8 tokens. Quoted arguments are not
/// supported (a documented limitation, not a bug). The token slices point
/// into the environ map's values, which live for the process; the array is
/// returned by value and is valid as long as the caller keeps the result.
pub const Args = struct {
    tokens: [8][]const u8,
    count: usize,

    /// A view into this value's tokens: valid only while `self` lives.
    pub fn slices(self: *const Args) []const []const u8 {
        return self.tokens[0..self.count];
    }
};

/// Split `spec` on runs of whitespace into at most 8 tokens (empty tokens
/// dropped). The token slices point into `spec`; the result carries no
/// allocation.
pub fn splitWhitespace(spec: []const u8) Args {
    var tokens: [8][]const u8 = undefined;
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= spec.len) : (i += 1) {
        const boundary = i == spec.len or std.ascii.isWhitespace(spec[i]);
        if (!boundary) continue;
        if (i > start and n < tokens.len) {
            tokens[n] = spec[start..i];
            n += 1;
        }
        start = i + 1;
    }
    return Args{ .tokens = tokens, .count = n };
}

pub const ParseArgsError = Allocator.Error || error{Usage};

/// `-t TAG` / `-tTAG` flags plus free text parts.
pub fn parseArgs(allocator: Allocator, rest: []const []const u8) ParseArgsError!ParsedArgs {
    var tags = std.ArrayList([]const u8).empty;
    errdefer tags.deinit(allocator);
    var parts = std.ArrayList([]const u8).empty;
    errdefer parts.deinit(allocator);
    var j: usize = 0;
    while (j < rest.len) : (j += 1) {
        const arg = rest[j];
        if (std.mem.eql(u8, arg, "-t")) {
            j += 1;
            if (j >= rest.len) return error.Usage;
            try tags.append(allocator, rest[j]);
        } else if (std.mem.startsWith(u8, arg, "-t") and arg.len > 2) {
            try tags.append(allocator, arg[2..]);
        } else {
            try parts.append(allocator, arg);
        }
    }
    return ParsedArgs{ .tags = tags, .parts = parts };
}

/// Joins parts with a single space (empty for no parts).
pub fn joinParts(allocator: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    var size: usize = 0;
    for (parts) |p| size += p.len + 1;
    const text = try allocator.alloc(u8, if (parts.len == 0) 0 else size - 1);
    var w: usize = 0;
    for (parts, 0..) |p, k| {
        if (k > 0) {
            text[w] = ' ';
            w += 1;
        }
        @memcpy(text[w .. w + p.len], p);
        w += p.len;
    }
    return text;
}

pub fn parseCivilDate(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u64, s[8..10], 10) catch return null;
    return core.view.dateToCivilDay(year, month, day);
}

/// `YYYY-MM-DD` (one day) or `YYYY-MM-DD:YYYY-MM-DD` (inclusive range).
pub fn parseDayRange(s: []const u8) ?core.view.DayRange {
    const split = std.mem.indexOfScalar(u8, s, ':');
    const start = parseCivilDate(s[0 .. split orelse s.len]) orelse return null;
    if (split) |c| {
        const end = parseCivilDate(s[c + 1 ..]) orelse return null;
        return core.view.DayRange{ .start = start, .end = end + 1 };
    }
    return core.view.DayRange{ .start = start, .end = start + 1 };
}

/// `YYYY-MM-DD..YYYY-MM-DD` (inclusive) or a single `YYYY-MM-DD`.
pub fn parseDotDayRange(s: []const u8) ?core.view.DayRange {
    const split = std.mem.indexOf(u8, s, "..") orelse {
        const day = parseCivilDate(s) orelse return null;
        return core.view.DayRange{ .start = day, .end = day + 1 };
    };
    const start = parseCivilDate(s[0..split]) orelse return null;
    const end = parseCivilDate(s[split + 2 ..]) orelse return null;
    if (end < start) return null;
    return core.view.DayRange{ .start = start, .end = end + 1 };
}

/// The Mon-Sun week containing now, under the journal's timezone.
pub fn currentWeek(journal: *const core.journal.Journal) errors.RunError!core.view.DayRange {
    const now_ms = cli_journal.nowMs(journal.io);
    const offset = try journal.tzOffsetMinutesAtMs(now_ms);
    const today = try core.view.localDay(now_ms, offset);
    const monday = core.view.weekStart(today);
    return core.view.DayRange{ .start = monday, .end = monday + 7 };
}
