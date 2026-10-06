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

/// Renders the LLM view for a full record stream (all segments, in order).
/// An empty stream renders to an empty string (spec section 9).
pub fn render(allocator: Allocator, headers: []const records.Header, payloads: []const []const u8) RenderError![]u8 {
    const n = headers.len;
    if (n == 0) return allocator.alloc(u8, 0);

    // First pass: gather per-entry state. Seq is dense from 0 (verify
    // guarantees this; the renderer refuses unverified logs at the call site).
    const types = try allocator.alloc(records.RecordType, n);
    const targets = try allocator.alloc(u64, n);
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
    @memset(tombstoned, false);
    @memset(redacted, false);
    @memset(edited, false);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = headers[i];
        const payload = try records.decodePayload(allocator, payloads[i]);
        tag_slices[i] = payload.tags;
        types[i] = h.record_type;
        targets[i] = h.target_seq;
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

    // Second pass: build viewable lines (spec section 9, rules 5-10).
    errdefer freeTagSlices(allocator, tag_slices);
    var lines = std.ArrayList(Line).empty;
    errdefer lines.deinit(allocator);
    i = 0;
    while (i < n) : (i += 1) {
        if (types[i] != .entry) continue;
        if (is_private[i]) continue;
        if (tombstoned[i]) continue;
        const h = headers[i];
        const day = localDay(h.timestamp_ms, h.tz_offset_min) catch return error.TimestampOutOfRange;
        try lines.append(allocator, Line{
            .day = day,
            .ts_ms = h.timestamp_ms,
            .tz_offset_min = h.tz_offset_min,
            .seq = h.seq,
            .redacted = redacted[i],
            .edited = edited[i],
            .text = effective_text[i],
            .tags = effective_tags[i],
        });
    }
    std.mem.sort(Line, lines.items, {}, lineLessThan);

    // Emit.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const last = headers[n - 1];
    try tryLine(allocator, &out, "# zephyr: seq 0..{d} head=", .{last.seq});
    try writeHexLower(allocator, &out, &last.record_hash);
    try out.append(allocator, '\n');

    var current_day: ?i64 = null;
    for (lines.items) |line| {
        if (current_day == null or current_day.? != line.day) {
            const date = civilDate(line.day) catch return error.TimestampOutOfRange;
            try tryLine(allocator, &out, "# {d:0>4}-{d:0>2}-{d:0>2} {s}", .{ date.year, date.month, date.day, weekdayName(line.day) });
            try out.append(allocator, '\n');
            current_day = line.day;
        }
        const time = timeString(line.ts_ms, line.tz_offset_min);
        var line_buf: [1 << 16]u8 = undefined;
        var written: usize = 0;
        written += (std.fmt.bufPrint(line_buf[written..], "{s}", .{time}) catch unreachable).len;
        if (line.redacted) {
            written += (std.fmt.bufPrint(line_buf[written..], " [redacted]", .{}) catch unreachable).len;
        } else {
            if (line.edited) {
                written += (std.fmt.bufPrint(line_buf[written..], " (edited)", .{}) catch unreachable).len;
            }
            if (line.tags.len > 0) {
                line_buf[written] = ' ';
                written += 1; // space before the tag block
                for (line.tags) |tag| {
                    written += (std.fmt.bufPrint(line_buf[written..], "[{s}]", .{tag}) catch unreachable).len;
                }
            }
            line_buf[written] = ' ';
            written += 1; // space before the text
            written += (std.fmt.bufPrint(line_buf[written..], "{s}", .{line.text}) catch unreachable).len;
        }
        try out.appendSlice(allocator, line_buf[0..written]);
        try out.append(allocator, '\n');
    }
    freeTagSlices(allocator, tag_slices);
    return out.toOwnedSlice(allocator);
}

fn freeTagSlices(allocator: Allocator, tag_slices: [][]const []const u8) void {
    for (tag_slices) |tags| allocator.free(tags);
}

const Line = struct {
    day: i64,
    ts_ms: u64,
    tz_offset_min: i16,
    seq: u64,
    redacted: bool,
    edited: bool,
    text: []const u8,
    tags: []const []const u8,
};

fn lineLessThan(_: void, a: Line, b: Line) bool {
    if (a.day != b.day) return a.day < b.day;
    if (a.ts_ms != b.ts_ms) return a.ts_ms < b.ts_ms;
    return a.seq < b.seq;
}

fn tryLine(allocator: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    try out.appendSlice(allocator, line);
}

fn writeHexLower(allocator: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    const digits = "0123456789abcdef";
    for (bytes) |b| {
        try out.append(allocator, digits[b >> 4]);
        try out.append(allocator, digits[b & 0x0F]);
    }
}

/// Local civil day (days since Unix epoch) of a timestamp under a fixed
/// minute offset — the "local date" the view groups by (spec section 9, rule 2).
fn localDay(ts_ms: u64, tz_offset_min: i16) !i64 {
    if (ts_ms > std.math.maxInt(i64)) return error.TimestampOutOfRange;
    const ts: i64 = @intCast(ts_ms);
    const local_ms: i64 = ts + @as(i64, tz_offset_min) * 60_000;
    return @divFloor(local_ms, 86_400_000);
}

const CivilDate = struct {
    year: u16,
    month: u4,
    day: u5,
};

fn civilDate(days: i64) !CivilDate {
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

/// Unix epoch day 0 (1970-01-01) was a Thursday.
fn weekdayName(days: i64) []const u8 {
    const names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const index: usize = @intCast(@rem(3 + days, 7));
    return names[index];
}

/// Local HH:MM of a timestamp under a fixed minute offset.
fn timeString(ts_ms: u64, tz_offset_min: i16) [5]u8 {
    // render() rejects out-of-range timestamps via localDay before calling this.
    if (ts_ms > std.math.maxInt(i64)) unreachable;
    const ts: i64 = @intCast(ts_ms);
    const local_ms: i64 = ts + @as(i64, tz_offset_min) * 60_000;
    var secs_of_day: i64 = @rem(@divFloor(local_ms, 1000), 86_400);
    if (secs_of_day < 0) secs_of_day += 86_400;
    // Format through unsigned types: 0.17 fmt prefixes a '+' on positive
    // signed ints when a width is given.
    const hh: u32 = @intCast(@divTrunc(secs_of_day, 3600));
    const mm: u32 = @intCast(@divTrunc(@rem(secs_of_day, 3600), 60));
    var buf: [5]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ hh, mm }) catch unreachable;
    var ret: [5]u8 = undefined;
    @memcpy(&ret, s);
    return ret;
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
    const expected = try allocator.print("# zephyr: seq 0..0 head={s}\n# 2026-01-02 Fri\n01:30 hello\n", .{hexOf(&entry.header.record_hash)});
    try std.testing.expectEqualStrings(expected, out);
}

test "provenance line uses final record hash" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const salt = [records.SaltLen]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
    const payload = records.Payload{ .salt = salt, .text = "hello", .tags = &.{} };
    var payload_bytes: [records.payloadSize("hello", &.{})]u8 = undefined;
    records.encodePayload(&payload, &payload_bytes);
    var header = records.Header{
        .version = records.FormatVersion,
        .record_type = .entry,
        .seq = 0,
        .timestamp_ms = 1_767_225_600_000, // 2026-01-01T00:00:00Z
        .tz_offset_min = 0,
        .flags = 0,
        .target_seq = 0,
        .commitment = records.computeCommitment(&payload_bytes),
        .record_hash = undefined,
    };
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.prefixBytes(&prefix);
    const genesis = records.Header.GenesisHash;
    header.record_hash = records.computeRecordHash(&prefix, &genesis);

    const out = try render(allocator, &.{header}, &.{&payload_bytes});
    const expected = try allocator.print("# zephyr: seq 0..0 head={s}\n# 2026-01-01 Thu\n00:00 hello\n", .{hexOf(&header.record_hash)});
    try std.testing.expectEqualStrings(expected, out);
}

fn hexOf(bytes: []const u8) [64]u8 {
    const digits = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}
