//! Deterministic LLM view renderer (spec section 9).
//!
//! Turns a verified record stream into the canonical text form. The output is
//! a pure function of the records; the golden bytes are pinned in
//! spec/vectors/journals.json.

const std = @import("std");
const records = @import("records.zig");
const epoch = std.time.epoch;

const Allocator = std.mem.Allocator;

pub const RenderError = Allocator.Error || records.DecodePayloadError || error{
    TimestampOutOfRange,
};

/// A civil-day interval, `start` inclusive, `end` exclusive, in days since
/// the Unix epoch.
pub const DayRange = struct {
    start: i64,
    end: i64,
};

/// One entry as the view shows it: a non-private, non-tombstoned entry with
/// its effective (latest-amendment) text and tags. `text` and the tag bytes
/// borrow from the payloads; the `tags` slice-header array is a fresh copy,
/// released by `Visible.deinit`.
pub const ViewEntry = struct {
    seq: u64,
    ts_ms: u64,
    tz_offset_min: i16,
    /// Local civil day the entry is grouped under.
    day: i64,
    redacted: bool,
    edited: bool,
    text: []const u8,
    tags: []const []const u8,
};

pub const Visible = struct {
    /// In view order: (local day, time, seq).
    entries: []ViewEntry,
    tag_lists: [][]const []const u8,
    allocator: Allocator,

    pub fn deinit(self: Visible) void {
        const allocator = self.allocator;
        for (self.tag_lists) |tags| allocator.free(tags);
        allocator.free(self.tag_lists);
        allocator.free(self.entries);
    }
};

fn viewEntryLessThan(_: void, a: ViewEntry, b: ViewEntry) bool {
    if (a.day != b.day) return a.day < b.day;
    if (a.ts_ms != b.ts_ms) return a.ts_ms < b.ts_ms;
    return a.seq < b.seq;
}

/// The viewable entries of a verified record stream (spec section 9,
/// rules 5-8): non-private, non-tombstoned, with the effective text and tags
/// after amendments (latest amendment wins). The single source of truth for
/// "what the view shows" — the renderer and search both consume it.
pub fn visibleEntries(allocator: Allocator, headers: []const records.Header, payloads: []const []const u8) RenderError!Visible {
    const n = headers.len;
    if (n == 0) return Visible{ .entries = &.{}, .tag_lists = &.{}, .allocator = allocator };

    // First pass: per-record state. Seq is dense from 0 (verify guarantees
    // this; callers refuse unverified logs).
    const types = try allocator.alloc(records.RecordType, n);
    const is_private = try allocator.alloc(bool, n);
    const tombstoned = try allocator.alloc(bool, n);
    const redacted = try allocator.alloc(bool, n);
    const effective_text = try allocator.alloc([]const u8, n);
    const effective_tags = try allocator.alloc([]const []const u8, n);
    const edited = try allocator.alloc(bool, n);
    // Every decodePayload call allocates a tag slice-header array, even when
    // the result is discarded or later overwritten; track all of them so none
    // leak.
    const tag_slices = try allocator.alloc([]const []const u8, n);
    errdefer {
        freeTagSlices(allocator, tag_slices);
        allocator.free(edited);
        allocator.free(effective_tags);
        allocator.free(effective_text);
        allocator.free(redacted);
        allocator.free(tombstoned);
        allocator.free(is_private);
        allocator.free(types);
    }
    @memset(tombstoned, false);
    @memset(redacted, false);
    @memset(edited, false);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = headers[i];
        const payload = try records.decodePayload(allocator, payloads[i]);
        tag_slices[i] = payload.tags;
        types[i] = h.record_type;
        is_private[i] = h.isPrivate();
        switch (h.record_type) {
            .entry => {
                effective_text[i] = payload.text;
                effective_tags[i] = payload.tags;
            },
            .amendment => {
                const t = h.target_seq;
                if (t < @as(u64, i) and types[@intCast(t)] == .entry) {
                    // Latest amendment wins: records are in seq order, so the
                    // last one processed is the latest.
                    effective_text[@intCast(t)] = payload.text;
                    effective_tags[@intCast(t)] = payload.tags;
                    edited[@intCast(t)] = true;
                }
            },
            .tombstone => {
                if (h.target_seq < @as(u64, i)) tombstoned[@intCast(h.target_seq)] = true;
            },
            .redaction => {
                if (h.target_seq < @as(u64, i)) redacted[@intCast(h.target_seq)] = true;
            },
            .checkpoint => {},
        }
    }

    // Second pass: keep the viewable entries, copying their effective tag
    // lists into owned memory (the per-record decode allocations are freed
    // before return).
    const entries = try allocator.alloc(ViewEntry, n);
    errdefer allocator.free(entries);
    var tag_lists = std.ArrayList([]const []const u8).empty;
    errdefer tag_lists.deinit(allocator);
    var count: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        if (types[i] != .entry or is_private[i] or tombstoned[i]) continue;
        const h = headers[i];
        const day = localDay(h.timestamp_ms, h.tz_offset_min) catch return error.TimestampOutOfRange;
        const etags = effective_tags[i];
        const tag_copy = try allocator.alloc([]const u8, etags.len);
        errdefer allocator.free(tag_copy);
        for (tag_copy, etags) |*slot, tag| slot.* = tag;
        try tag_lists.append(allocator, tag_copy);
        entries[count] = .{
            .seq = h.seq,
            .ts_ms = h.timestamp_ms,
            .tz_offset_min = h.tz_offset_min,
            .day = day,
            .redacted = redacted[i],
            .edited = edited[i],
            .text = effective_text[i],
            .tags = tag_copy,
        };
        count += 1;
    }
    std.mem.sort(ViewEntry, entries[0..count], {}, viewEntryLessThan);

    const owned_tag_lists = try tag_lists.toOwnedSlice(allocator);
    errdefer allocator.free(owned_tag_lists);
    // Success path: release the first-pass scratch arrays (the errdefer above
    // covers them on error, but never runs after this point).
    freeTagSlices(allocator, tag_slices);
    allocator.free(edited);
    allocator.free(effective_tags);
    allocator.free(effective_text);
    allocator.free(redacted);
    allocator.free(tombstoned);
    allocator.free(is_private);
    allocator.free(types);
    return Visible{ .entries = entries[0..count], .tag_lists = owned_tag_lists, .allocator = allocator };
}

/// Renders the LLM view for a full record stream (all segments, in order).
/// An empty stream renders to an empty string (spec section 9).
pub fn render(allocator: Allocator, headers: []const records.Header, payloads: []const []const u8) RenderError![]u8 {
    return renderRange(allocator, headers, payloads, null);
}

/// Renders the view restricted to entries whose local day falls in `range`
/// (start inclusive, end exclusive). Day headers stand alone, entry lines
/// carry the bare seq, and days are separated by a blank line; an empty
/// journal or a range with no entries renders empty (spec section 9).
pub fn renderRange(allocator: Allocator, headers: []const records.Header, payloads: []const []const u8, range: ?DayRange) RenderError![]u8 {
    const n = headers.len;
    if (n == 0) return allocator.alloc(u8, 0);

    const visible = try visibleEntries(allocator, headers, payloads);
    defer visible.deinit();

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var seq_buf: [20]u8 = undefined; // u64 decimal
    var current_day: ?i64 = null;
    for (visible.entries) |entry| {
        if (range) |r| {
            if (entry.day < r.start or entry.day >= r.end) continue;
        }
        if (current_day == null or current_day.? != entry.day) {
            if (out.items.len > 0) try out.append(allocator, '\n'); // blank line between days
            const date = civilDate(entry.day) catch return error.TimestampOutOfRange;
            try tryLine(allocator, &out, "{d:0>4}-{d:0>2}-{d:0>2} {s}", .{ date.year, date.month, date.day, weekdayName(entry.day) });
            try out.append(allocator, '\n');
            current_day = entry.day;
        }
        const seq_digits = std.fmt.bufPrint(&seq_buf, "{d}", .{entry.seq}) catch unreachable;
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, seq_digits);
        try out.appendSlice(allocator, "  ");
        const line = try entryLine(allocator, entry);
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// The exact line the view renderer emits for `entry` — the time, the
/// redaction or edit marker, the tag block, and the text — without the
/// trailing newline. The Phase 4 vectors pin its bytes; the embedding
/// input for an entry is this line (spec/semantic.md section 4).
pub fn entryLine(allocator: Allocator, entry: ViewEntry) RenderError![]u8 {
    var line_buf: [1 << 16]u8 = undefined;
    var written: usize = 0;
    const time = timeString(entry.ts_ms, entry.tz_offset_min);
    written += (std.fmt.bufPrint(line_buf[written..], "{s}", .{time}) catch unreachable).len;
    if (entry.redacted) {
        written += (std.fmt.bufPrint(line_buf[written..], " [redacted]", .{}) catch unreachable).len;
    } else {
        if (entry.edited) {
            written += (std.fmt.bufPrint(line_buf[written..], " (edited)", .{}) catch unreachable).len;
        }
        if (entry.tags.len > 0) {
            line_buf[written] = ' ';
            written += 1; // space before the tag block
            for (entry.tags) |tag| {
                written += (std.fmt.bufPrint(line_buf[written..], "[{s}]", .{tag}) catch unreachable).len;
            }
        }
        line_buf[written] = ' ';
        written += 1; // space before the text
        written += (std.fmt.bufPrint(line_buf[written..], "{s}", .{entry.text}) catch unreachable).len;
    }
    return allocator.dupe(u8, line_buf[0..written]);
}

fn freeTagSlices(allocator: Allocator, tag_slices: [][]const []const u8) void {
    for (tag_slices) |tags| allocator.free(tags);
}

fn tryLine(allocator: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    try out.appendSlice(allocator, line);
}

/// The singular or plural form of a count noun ("record" / "records") —
/// the core twin of the CLI's output.countNoun (core cannot import it).
pub fn countNoun(count: u64, comptime singular: []const u8, comptime plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
}

/// Local civil day (days since Unix epoch) of a timestamp under a fixed
/// minute offset — the "local date" the view groups by (spec section 9, rule 2).
pub fn localDay(ts_ms: u64, tz_offset_min: i16) !i64 {
    if (ts_ms > std.math.maxInt(i64)) return error.TimestampOutOfRange;
    const ts: i64 = @intCast(ts_ms);
    const local_ms: i64 = ts + @as(i64, tz_offset_min) * 60_000;
    return @divFloor(local_ms, 86_400_000);
}

pub const CivilDate = struct {
    year: u16,
    month: u4,
    day: u5,
};

pub fn civilDate(days: i64) !CivilDate {
    if (days < 0) return error.TimestampOutOfRange;
    const epoch_day = epoch.EpochDay{ .day = @intCast(days) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return CivilDate{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
    };
}

/// Civil day (days since the Unix epoch) of the proleptic Gregorian date
/// `year-month-day`, or null if the date does not exist (e.g. Feb 30).
pub fn dateToCivilDay(year: i64, month: u64, day: u64) ?i64 {
    if (year < 1 or month < 1 or month > 12 or day < 1 or day > 31) return null;
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const days = daysFromCivil(year, m, d);
    if (days < 0) return null;
    const c = civilDate(days) catch return null;
    if (c.year != @as(u16, @intCast(year)) or @as(u64, c.month) != month or @as(u64, c.day) != day) return null;
    return days;
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01 for a proleptic
/// Gregorian date.
fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    var yy = y;
    if (m <= 2) yy -= 1;
    const era: i64 = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp: i64 = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719_468;
}

/// The Monday (as a civil day) of the ISO week containing `day`.
pub fn weekStart(day: i64) i64 {
    return day - @as(i64, @mod(day + 3, 7));
}

/// Monday-first weekday names (index 0 = Monday).
pub const Weekdays = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

/// The Monday-first weekday index (0 = Monday) of `days`: Unix epoch day 0
/// (1970-01-01) was a Thursday.
pub fn weekdayIndex(days: i64) u8 {
    return @intCast(@rem(3 + days, 7));
}

pub fn weekdayName(days: i64) []const u8 {
    return Weekdays[weekdayIndex(days)];
}

/// The local wall-clock hour (0-23) of a timestamp under a fixed minute
/// offset.
pub fn hourOf(ts_ms: u64, tz_offset_min: i16) u32 {
    // render() rejects out-of-range timestamps via localDay before calling this.
    if (ts_ms > std.math.maxInt(i64)) unreachable;
    const ts: i64 = @intCast(ts_ms);
    const local_ms: i64 = ts + @as(i64, tz_offset_min) * 60_000;
    var secs_of_day: i64 = @rem(@divFloor(local_ms, 1000), 86_400);
    if (secs_of_day < 0) secs_of_day += 86_400;
    return @intCast(@divTrunc(secs_of_day, 3600));
}

/// The local time band of an hour (spec/derived.md section 6): 0 morning
/// 05–12, 1 afternoon 12–17, 2 evening 17–23, 3 night 23–05.
pub fn timeBand(hour: u32) u32 {
    if (hour >= 23 or hour < 5) return 3;
    if (hour < 12) return 0;
    if (hour < 17) return 1;
    return 2;
}

/// Local HH:MM of a timestamp under a fixed minute offset.
pub fn timeString(ts_ms: u64, tz_offset_min: i16) [5]u8 {
    // Format through unsigned types: 0.17 fmt prefixes a '+' on positive
    // signed ints when a width is given.
    const hh: u32 = hourOf(ts_ms, tz_offset_min);
    const mm: u32 = @intCast(@divTrunc(@rem(secsOfDay(ts_ms, tz_offset_min), 3600), 60));
    var buf: [5]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ hh, mm }) catch unreachable;
    var ret: [5]u8 = undefined;
    @memcpy(&ret, s);
    return ret;
}

/// Local seconds-of-day (0-86399) of a timestamp under a fixed minute
/// offset.
fn secsOfDay(ts_ms: u64, tz_offset_min: i16) i64 {
    // render() rejects out-of-range timestamps via localDay before calling this.
    if (ts_ms > std.math.maxInt(i64)) unreachable;
    const ts: i64 = @intCast(ts_ms);
    const local_ms: i64 = ts + @as(i64, tz_offset_min) * 60_000;
    var secs_of_day: i64 = @rem(@divFloor(local_ms, 1000), 86_400);
    if (secs_of_day < 0) secs_of_day += 86_400;
    return secs_of_day;
}

test "empty journal renders empty" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

fn makeEntry(allocator: Allocator, text: []const u8, ts_ms: u64, tz: i16, prev: *const [records.DigestLen]u8) Allocator.Error!struct {
    header: records.Header,
    payload: []u8,
} {
    const salt = [records.SaltLen]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
    const payload = records.Payload{ .salt = salt, .text = text, .tags = &.{} };
    const payload_bytes = try allocator.alloc(u8, records.payloadSize(text, &.{}));
    records.encodePayload(&payload, payload_bytes);
    var header = records.Header{
        .version = records.FormatVersion,
        .record_type = .entry,
        .seq = 0,
        .timestamp_ms = ts_ms,
        .tz_offset_min = tz,
        .flags = 0,
        .target_seq = 0,
        .commitment = records.computeCommitment(payload_bytes),
        .record_hash = undefined,
    };
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.prefixBytes(&prefix);
    header.record_hash = records.computeRecordHash(&prefix, prev);
    return .{ .header = header, .payload = payload_bytes };
}

test "local date rolls past midnight" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 2026-01-01T23:30:00Z at +02:00 is 2026-01-02 01:30 locally.
    const genesis = records.Header.GenesisHash;
    const entry = try makeEntry(allocator, "hello", 1_767_310_200_000, 120, &genesis);

    const out = try render(allocator, &.{entry.header}, &.{entry.payload});
    const expected = "2026-01-02 Fri\n  0  01:30 hello\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "renderRange filters by local day" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Two entries on different local days, chained from genesis, +120 offset.
    // e0: 2026-01-15T23:45:00Z -> local 2026-01-16 01:45 (crosses midnight)
    // e1: 2026-01-17T22:00:00Z -> local 2026-01-18 00:00 (exactly midnight)
    const genesis = records.Header.GenesisHash;
    const e0 = try makeEntry(allocator, "before midnight", 1_768_520_700_000, 120, &genesis);
    var e1 = try makeEntry(allocator, "at midnight", 1_768_687_200_000, 120, &e0.header.record_hash);
    e1.header.seq = 1;
    e1.header.record_hash = recompute(&e1.header, &e0.header.record_hash);
    const headers = [_]records.Header{ e0.header, e1.header };
    const payloads = [_][]const u8{ e0.payload, e1.payload };

    const day16 = dateToCivilDay(2026, 1, 16) orelse unreachable;
    const day17 = dateToCivilDay(2026, 1, 17) orelse unreachable;
    const day18 = dateToCivilDay(2026, 1, 18) orelse unreachable;

    // Only the entry whose local day is 2026-01-16, even though its UTC date
    // is 2026-01-15.
    const got = try renderRange(allocator, &headers, &payloads, .{ .start = day16, .end = day16 + 1 });
    try std.testing.expectEqualStrings("2026-01-16 Fri\n  0  01:45 before midnight\n", got);

    // A range with no entries renders empty.
    const empty = try renderRange(allocator, &headers, &payloads, .{ .start = day17, .end = day17 + 1 });
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // The entry at exactly local midnight belongs to 2026-01-18, not 01-17.
    const at_midnight = try renderRange(allocator, &headers, &payloads, .{ .start = day18, .end = day18 + 1 });
    try std.testing.expectEqualStrings("2026-01-18 Sun\n  1  00:00 at midnight\n", at_midnight);
}

test "dateToCivilDay and weekStart" {
    // 2026-01-16 is a Friday (2026-01-01 is a Thursday).
    const friday = dateToCivilDay(2026, 1, 16) orelse unreachable;
    try std.testing.expectEqualStrings("Fri", weekdayName(friday));
    // 2026-09-14 is a Monday (the README example).
    const monday = dateToCivilDay(2026, 9, 14) orelse unreachable;
    try std.testing.expectEqualStrings("Mon", weekdayName(monday));
    try std.testing.expectEqual(monday, weekStart(monday));
    try std.testing.expectEqual(monday + 7, weekStart(monday + 7));
    // The Monday of the week containing 2026-01-16 (a Friday) is 2026-01-12.
    const jan12 = dateToCivilDay(2026, 1, 12) orelse unreachable;
    try std.testing.expectEqualStrings("Mon", weekdayName(jan12));
    try std.testing.expectEqual(jan12, weekStart(friday));
    // Leap-year boundary.
    const leap = dateToCivilDay(2028, 2, 29) orelse unreachable;
    try std.testing.expectEqualStrings("Tue", weekdayName(leap));
    // Invalid dates.
    try std.testing.expect(dateToCivilDay(2026, 2, 29) == null);
    try std.testing.expect(dateToCivilDay(2026, 13, 1) == null);
    try std.testing.expect(dateToCivilDay(2026, 0, 1) == null);
    try std.testing.expect(dateToCivilDay(2026, 4, 31) == null);
    // Round trip through civilDate.
    const c = try civilDate(friday);
    try std.testing.expectEqual(@as(u16, 2026), c.year);
    try std.testing.expectEqual(@as(u64, 1), @as(u64, c.month));
    try std.testing.expectEqual(@as(u64, 16), @as(u64, c.day));
}

test "visibleEntries: amendments, tombstones, private, ordering" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const genesis = records.Header.GenesisHash;
    // seq 0: entry; seq 1: private entry; seq 2: entry to amend; seq 3: entry
    // to tombstone; seq 4: amendment -> 2; seq 5: tombstone -> 3.
    const h0 = try makeEntry(allocator, "a", 1_767_225_600_000, 0, &genesis);
    var h1 = try makeEntry(allocator, "secret", 1_767_225_660_000, 0, &h0.header.record_hash);
    var h2 = try makeEntry(allocator, "original", 1_767_225_720_000, 0, &h1.header.record_hash);
    var h3 = try makeEntry(allocator, "doomed", 1_767_225_780_000, 0, &h2.header.record_hash);
    var h4 = try makeEntry(allocator, "amended", 1_767_312_000_000, 0, &h3.header.record_hash);
    var h5 = try makeEntry(allocator, "", 1_767_312_060_000, 0, &h4.header.record_hash);
    // makeEntry stamps seq 0; set the real header fields and re-hash (seq is
    // in the hashed prefix).
    h1.header.flags = records.FlagPrivate;
    h2.header.seq = 2;
    h3.header.seq = 3;
    h4.header.record_type = .amendment;
    h4.header.target_seq = 2;
    h4.header.seq = 4;
    h5.header.record_type = .tombstone;
    h5.header.target_seq = 3;
    h5.header.seq = 5;
    h1.header.record_hash = recompute(&h1.header, &h0.header.record_hash);
    h2.header.record_hash = recompute(&h2.header, &h1.header.record_hash);
    h3.header.record_hash = recompute(&h3.header, &h2.header.record_hash);
    h4.header.record_hash = recompute(&h4.header, &h3.header.record_hash);
    h5.header.record_hash = recompute(&h5.header, &h4.header.record_hash);

    const headers = [_]records.Header{ h0.header, h1.header, h2.header, h3.header, h4.header, h5.header };
    const payloads = [_][]const u8{ h0.payload, h1.payload, h2.payload, h3.payload, h4.payload, h5.payload };

    const visible = try visibleEntries(allocator, &headers, &payloads);
    defer visible.deinit();
    try std.testing.expectEqual(@as(usize, 2), visible.entries.len);
    // The private and tombstoned entries are gone.
    try std.testing.expectEqual(@as(u64, 0), visible.entries[0].seq);
    try std.testing.expectEqualStrings("a", visible.entries[0].text);
    try std.testing.expectEqual(@as(u64, 2), visible.entries[1].seq);
    // Latest amendment wins, and the entry is marked edited.
    try std.testing.expectEqualStrings("amended", visible.entries[1].text);
    try std.testing.expect(visible.entries[1].edited);
}

fn recompute(header: *records.Header, prev: *const [records.DigestLen]u8) [records.DigestLen]u8 {
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.record_hash = @splat(0); // record_hash is not in the prefix; zero for clarity
    header.prefixBytes(&prefix);
    return records.computeRecordHash(&prefix, prev);
}

test "render: day headers, bare seqs, and the blank line between days" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Two entries on consecutive days, chained from genesis, UTC.
    const genesis = records.Header.GenesisHash;
    const e0 = try makeEntry(allocator, "hello", 1_767_225_600_000, 0, &genesis); // 2026-01-01T00:00:00Z
    var e1 = try makeEntry(allocator, "world", 1_767_317_400_000, 0, &e0.header.record_hash); // 2026-01-02T01:30:00Z
    e1.header.seq = 1;
    e1.header.record_hash = recompute(&e1.header, &e0.header.record_hash);
    const headers = [_]records.Header{ e0.header, e1.header };
    const payloads = [_][]const u8{ e0.payload, e1.payload };

    const out = try render(allocator, &headers, &payloads);
    const want = "2026-01-01 Thu\n  0  00:00 hello\n\n2026-01-02 Fri\n  1  01:30 world\n";
    try std.testing.expectEqualStrings(want, out);
}
