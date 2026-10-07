//! Keyword search over the viewable entries (CLI: zephyr search).
//!
//! Matches a case-insensitive substring against the effective text of the
//! entries the LLM view shows (non-private, non-tombstoned, non-redacted).
//! Superseded original text of amended entries is not searched — only what
//! the view would show.

const std = @import("std");
const records = @import("records.zig");
const view = @import("view.zig");

const Allocator = std.mem.Allocator;

pub const RenderError = view.RenderError;

pub const Match = struct {
    seq: u64,
    day: i64,
    ts_ms: u64,
    tz_offset_min: i16,
    /// Borrows from `visible` / the payloads.
    text: []const u8,
    tags: []const []const u8,
};

/// Case-insensitive substring matches over `visible.entries`, in view order.
/// An empty query matches nothing.
pub fn find(allocator: Allocator, visible: *const view.Visible, query: []const u8) RenderError![]Match {
    var matches = std.ArrayList(Match).empty;
    errdefer matches.deinit(allocator);
    if (query.len > 0) {
        for (visible.entries) |entry| {
            if (entry.redacted) continue;
            if (containsInsensitive(entry.text, query)) {
                try matches.append(allocator, .{
                    .seq = entry.seq,
                    .day = entry.day,
                    .ts_ms = entry.ts_ms,
                    .tz_offset_min = entry.tz_offset_min,
                    .text = entry.text,
                    .tags = entry.tags,
                });
            }
        }
    }
    return matches.toOwnedSlice(allocator);
}

/// Renders matches: a count line, then one line per match:
/// `{seq:0>4}  YYYY-MM-DD HH:MM  [tag]... text`
pub fn render(allocator: Allocator, matches: []const Match, query: []const u8) RenderError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const plural = if (matches.len == 1) "" else "es";
    try tryLine(allocator, &out, "# {d} match{s} for \"{s}\"", .{ matches.len, plural, query });
    try out.append(allocator, '\n');
    for (matches) |m| {
        const date = view.civilDate(m.day) catch return error.TimestampOutOfRange;
        const time = view.timeString(m.ts_ms, m.tz_offset_min);
        try tryLine(allocator, &out, "{d:0>4}  {d:0>4}-{d:0>2}-{d:0>2} {s}  ", .{
            m.seq, date.year, date.month, date.day, time,
        });
        for (m.tags) |tag| {
            try tryLine(allocator, &out, "[{s}]", .{tag});
        }
        if (m.tags.len > 0) try out.append(allocator, ' ');
        try tryLine(allocator, &out, "{s}", .{m.text});
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Match lines carry the full entry text (up to the format's 64 KB text cap),
/// so the line buffer matches the view renderer's line buffer.
fn tryLine(allocator: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var buf: [1 << 16]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    try out.appendSlice(allocator, line);
}

test "search: case-insensitive substring, viewable entries only" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const genesis = records.Header.GenesisHash;
    // seq 0: entry "bought MILK"; seq 1: entry with tag; seq 2: private.
    const h0 = try makeEntry(allocator, "bought milk", 1_767_225_600_000, 0, &genesis);
    const h1 = try makeEntry(allocator, "walked", 1_767_225_660_000, 0, &h0.header.record_hash);
    const h2 = try makeEntry(allocator, "SECRET milk run", 1_767_225_720_000, 0, &h1.header.record_hash);
    h2.header.flags = records.FlagPrivate;
    h2.header.seq = 2;
    h2.header.record_hash = recompute(&h2.header, &h1.header.record_hash);

    const headers = [_]records.Header{ h0.header, h1.header, h2.header };
    const payloads = [_][]const u8{ &h0.payload, &h1.payload, &h2.payload };

    const visible = try view.visibleEntries(allocator, &headers, &payloads);
    defer visible.deinit();

    // Case-insensitive: "MILK" matches "bought milk" but not the private one.
    const milk = try find(allocator, &visible, "MILK");
    defer allocator.free(milk);
    try std.testing.expectEqual(@as(usize, 1), milk.len);
    try std.testing.expectEqual(@as(u64, 0), milk[0].seq);

    const no_match = try find(allocator, &visible, "zebra");
    defer allocator.free(no_match);
    try std.testing.expectEqual(@as(usize, 0), no_match.len);

    const empty_query = try find(allocator, &visible, "");
    defer allocator.free(empty_query);
    try std.testing.expectEqual(@as(usize, 0), empty_query.len);

    // Rendered output for the "MILK" query (no tags on the match).
    const rendered = try render(allocator, milk, "MILK");
    defer allocator.free(rendered);
    const want = "# 1 match for \"MILK\"\n0000  2026-01-01 00:00  bought milk\n";
    try std.testing.expectEqualStrings(want, rendered);

    const none = try render(allocator, no_match, "zebra");
    defer allocator.free(none);
    try std.testing.expectEqualStrings("# 0 matches for \"zebra\"\n", none);
}

// Local copies of the view test helpers (kept private there).
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

fn recompute(header: *records.Header, prev: *const [records.DigestLen]u8) [records.DigestLen]u8 {
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.record_hash = @splat(0);
    header.prefixBytes(&prefix);
    return records.computeRecordHash(&prefix, prev);
}
