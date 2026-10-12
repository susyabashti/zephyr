//! Phase 6 gate: the MCP server (spec/mcp.md).
//!
//! Drives the real server (lifecycle, dispatch, tools) in-process against an
//! on-disk fixture journal:
//!   - the initialize/ping/tools handshake and lifecycle enforcement;
//!   - get_entries and search respect the view rules (private excluded,
//!     redacted marker, case-insensitive search, limit + truncation note);
//!   - every response carries the provenance line;
//!   - a corrupted chain is flagged by verify_status and every data tool
//!     refuses;
//!   - add_entry is absent by default, cannot be enabled from a request,
//!     and appends when the server was started with --allow-write.
//!
//! The cross-process transport contract (real stdio, independent client) is
//! the gate in test/mcpref.py.

const std = @import("std");
const core = @import("zephyr_core");
const mcp = @import("zephyr_mcp");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const protocol = mcp.protocol;
const server = mcp.server;

// ---------------------------------------------------------------- fixtures

fn makeJournal(
    allocator: Allocator,
    io: Io,
    dir_name: []const u8,
) (Allocator.Error || Dir.DeleteTreeError || core.journal.OpenError)!core.journal.Journal {
    const cwd = Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/{s}", .{ cwd_path, dir_name });
    const environ = std.process.Environ.Map.init(allocator);
    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    return core.journal.Journal.open(allocator, io, &environ, path, true);
}

/// The shared fixture: five records, one UTC day (2026-01-01, a Thursday).
///   seq 0: [work] "shipped the auth fix"        01:00
///   seq 1: private "PRIVATE-MCP-MARKER-4d7e"    02:00
///   seq 2: "sensitive meeting notes"  03:00  (redacted below)
///   seq 3: "walked the dog"            04:00
///   seq 4: redaction of seq 2          05:00
fn fillFixture(allocator: Allocator, journal: *const core.journal.Journal) (core.journal.Journal.AppendError || core.journal.Journal.RedactError)!void {
    const base: u64 = 1_767_225_600_000; // 2026-01-01T00:00:00Z
    _ = try journal.appendRecord(allocator, .entry, 0, "shipped the auth fix", &.{"work"}, base + 3_600_000, 0, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "PRIVATE-MCP-MARKER-4d7e", &.{"priv"}, base + 7_200_000, 0, true);
    _ = try journal.appendRecord(allocator, .entry, 0, "sensitive meeting notes", &.{}, base + 10_800_000, 0, false);
    _ = try journal.appendRecord(allocator, .entry, 0, "walked the dog", &.{}, base + 14_400_000, 0, false);
    _ = try journal.redact(allocator, 2, base + 18_000_000, 0);
}

/// One scripted server. The journal and the struct live in the caller's
/// arena, so pointers into them are stable for the test's lifetime.
fn line(
    allocator: Allocator,
    id: []const u8,
    method: []const u8,
    params: ?[]const u8,
) Allocator.Error![]const u8 {
    return if (params) |p|
        allocator.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p })
    else
        allocator.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"method\":\"{s}\"}}", .{ id, method });
}

fn notify(allocator: Allocator, method: []const u8) Allocator.Error![]const u8 {
    return allocator.print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}", .{method});
}

const FixtureServer = struct {
    journal: *core.journal.Journal,
    srv: server.Server,
    io: Io,

    fn init(
        allocator: Allocator,
        io: Io,
        dir_name: []const u8,
        allow_write: bool,
    ) (Allocator.Error || Dir.DeleteTreeError || core.journal.OpenError)!*FixtureServer {
        const self = try allocator.create(FixtureServer);
        errdefer allocator.destroy(self);
        const j = try allocator.create(core.journal.Journal);
        errdefer allocator.destroy(j);
        j.* = try makeJournal(allocator, io, dir_name);
        self.* = .{ .journal = j, .srv = server.Server.init(j, allow_write), .io = io };
        return self;
    }

    fn deinit(self: *FixtureServer, allocator: Allocator) void {
        self.journal.close();
        Dir.deleteTree(Dir.cwd(), self.io, self.journal.path) catch |e| if (e != error.FileNotFound)
            std.debug.panic("could not clean up: {s}", .{@errorName(e)});
        _ = allocator; // arena frees the structs
    }

    /// Sends one line; returns the response written by that line (empty for
    /// notifications). The result is owned by the caller's allocator.
    fn send(
        self: *FixtureServer,
        allocator: Allocator,
        msg: []const u8,
    ) (Allocator.Error || Io.Writer.Error)![]const u8 {
        var buf: [8192]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try self.srv.handleLine(allocator, self.io, msg, &w);
        return allocator.dupe(u8, w.buffered());
    }

    /// The full handshake: initialize + notifications/initialized. Returns
    /// the initialize response.
    fn handshake(self: *FixtureServer, allocator: Allocator, version: []const u8) (Allocator.Error || Io.Writer.Error)![]const u8 {
        const init_params = try allocator.print(
            "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"test\",\"version\":\"0\"}}}}",
            .{version},
        );
        defer allocator.free(init_params);
        const init_line = try line(allocator, "1", "initialize", init_params);
        defer allocator.free(init_line);
        const resp = try self.send(allocator, init_line);
        const note = try notify(allocator, "notifications/initialized");
        defer allocator.free(note);
        _ = try self.send(allocator, note);
        return resp;
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn json(allocator: Allocator, msg: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, msg, .{}) catch
        std.debug.panic("test fixture is not valid JSON: {s}", .{msg});
}

/// The text content of a tools/call result.
fn toolText(allocator: Allocator, response: []const u8) Allocator.Error![]const u8 {
    const v = json(allocator, response);
    const result = v.object.get("result") orelse std.debug.panic("no result in: {s}", .{response});
    const content = result.object.get("content").?;
    const first = content.array.items[0];
    return first.object.get("text").?.string;
}

fn isToolError(allocator: Allocator, response: []const u8) Allocator.Error!bool {
    const v = json(allocator, response);
    const flag = v.object.get("result").?.object.get("isError") orelse return false;
    return if (flag == .bool) flag.bool else false;
}

fn rpcErrorCode(allocator: Allocator, response: []const u8) Allocator.Error!i64 {
    const v = json(allocator, response);
    return v.object.get("error").?.object.get("code").?.integer;
}

fn headOf(allocator: Allocator, journal: *const core.journal.Journal) (Allocator.Error || core.journal.Journal.VerifyError)![]const u8 {
    const result = try journal.verify(allocator);
    if (!result.ok) std.debug.panic("fixture journal should verify", .{});
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, result.head.len * 2);
    for (result.head, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}

// ---------------------------------------------------------------- tests

test "phase 6: handshake, capabilities, and lifecycle" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-a", false);
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);

    // initialize echoes a supported version and advertises tools only.
    const init_resp = try f.handshake(allocator, "2025-06-18");
    const init_v = json(allocator, init_resp);
    try std.testing.expectEqualStrings("2025-06-18", init_v.object.get("result").?.object.get("protocolVersion").?.string);
    const caps = init_v.object.get("result").?.object.get("capabilities").?.object;
    try std.testing.expect(caps.get("tools") != null);
    try std.testing.expect(caps.get("prompts") == null);
    try std.testing.expect(caps.get("resources") == null);
    const info = init_v.object.get("result").?.object.get("serverInfo").?.object;
    try std.testing.expectEqualStrings("zephyr", info.get("name").?.string);
    try std.testing.expectEqualStrings(server.Version, info.get("version").?.string);

    // An unsupported requested version gets the server's latest; the older
    // supported version is echoed.
    var f2 = try FixtureServer.init(allocator, io, ".tmp-phase6-b", false);
    defer f2.deinit(allocator);
    const resp2 = try f2.handshake(allocator, "1999-01-01");
    const v2 = json(allocator, resp2);
    try std.testing.expectEqualStrings(server.LatestProtocolVersion, v2.object.get("result").?.object.get("protocolVersion").?.string);

    var f3 = try FixtureServer.init(allocator, io, ".tmp-phase6-c", false);
    defer f3.deinit(allocator);
    const resp3 = try f3.handshake(allocator, "2025-03-26");
    const v3 = json(allocator, resp3);
    try std.testing.expectEqualStrings("2025-03-26", v3.object.get("result").?.object.get("protocolVersion").?.string);
    const ping_resp = try f3.send(allocator, try line(allocator, "9", "ping", null));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}" ++ "\n", ping_resp);

    // Lifecycle: a second initialize is rejected...
    const reinit_resp = try f3.send(allocator, try line(allocator, "10", "initialize", "{\"protocolVersion\":\"2025-06-18\"}"));
    try std.testing.expectEqual(@as(i64, -32600), try rpcErrorCode(allocator, reinit_resp));

    // ...and a data request before the initialized notification is rejected,
    // echoing the request's id.
    var f4 = try FixtureServer.init(allocator, io, ".tmp-phase6-d", false);
    defer f4.deinit(allocator);
    const early_resp = try f4.send(allocator, try line(allocator, "2", "tools/list", null));
    try std.testing.expectEqual(@as(i64, -32600), try rpcErrorCode(allocator, early_resp));
    try std.testing.expectEqual(@as(i64, 2), json(allocator, early_resp).object.get("id").?.integer);
}

test "phase 6: tools/list advertises read-only tools and the gated write tool" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-e", false);
    defer f.deinit(allocator);
    _ = try f.handshake(allocator, "2025-06-18");
    const resp = try f.send(allocator, try line(allocator, "3", "tools/list", null));
    const v = json(allocator, resp);
    const tool_list = v.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 6), tool_list.items.len);
    // Phase 7 adds get_context; add_entry (below) stays the only gated tool.
    const names = [_][]const u8{ "get_entries", "search", "get_digest", "get_profile", "verify_status", "get_context" };
    for (names, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, tool_list.items[i].object.get("name").?.string);
        try std.testing.expect(tool_list.items[i].object.get("inputSchema") != null);
        try std.testing.expect(tool_list.items[i].object.get("description") != null);
    }

    var w = try FixtureServer.init(allocator, io, ".tmp-phase6-f", true);
    defer w.deinit(allocator);
    _ = try w.handshake(allocator, "2025-06-18");
    const resp2 = try w.send(allocator, try line(allocator, "4", "tools/list", null));
    const v2 = json(allocator, resp2);
    const list2 = v2.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 7), list2.items.len);
    try std.testing.expectEqualStrings("add_entry", list2.items[6].object.get("name").?.string);
}

test "phase 6: get_entries serves the date and hides private and redacted content" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-g", false);
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    _ = try f.handshake(allocator, "2025-06-18");

    const resp = try f.send(allocator, try line(allocator, "5", "tools/call", try allocator.print("{{\"name\":\"get_entries\",\"arguments\":{s}}}", .{"{\"from\":\"2026-01-01\",\"to\":\"2026-01-01\"}"})));
    const text = try toolText(allocator, resp);
    try std.testing.expect(!(try isToolError(allocator, resp)));

    // Provenance line first (spec/mcp.md section 3), then the view.
    try std.testing.expect(contains(text, "# zephyr: seq 0..4 head="));
    try std.testing.expect(contains(text, "# 2026-01-01 Thu"));
    try std.testing.expect(contains(text, "01:00 [work] shipped the auth fix"));
    try std.testing.expect(contains(text, "03:00 [redacted]"));
    try std.testing.expect(contains(text, "04:00 walked the dog"));
    // Private and redacted content never appears.
    try std.testing.expect(!contains(text, "PRIVATE-MCP-MARKER-4d7e"));
    try std.testing.expect(!contains(text, "[priv]"));
    try std.testing.expect(!contains(text, "sensitive meeting notes"));

    // A verified journal with no entries in range is served as the
    // provenance line alone.
    const resp2 = try f.send(allocator, try line(allocator, "6", "tools/call", try allocator.print("{{\"name\":\"get_entries\",\"arguments\":{s}}}", .{"{\"from\":\"2026-01-02\"}"})));
    const text2 = try toolText(allocator, resp2);
    const head = try headOf(allocator, f.journal);
    defer allocator.free(head);
    const want = try allocator.print("# zephyr: seq 0..4 head={s}\n", .{head});
    try std.testing.expectEqualStrings(want, text2);
}

test "phase 6: search is case-insensitive, respects limit, never matches private" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-h", false);
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    _ = try f.handshake(allocator, "2025-06-18");

    // "the" matches two entries (seq 0 and seq 3); limit 1 truncates.
    const resp = try f.send(allocator, try line(allocator, "7", "tools/call", try allocator.print("{{\"name\":\"search\",\"arguments\":{s}}}", .{"{\"query\":\"THE\",\"limit\":1}"})));
    const text = try toolText(allocator, resp);
    try std.testing.expect(contains(text, "# zephyr: seq 0..4 head="));
    try std.testing.expect(contains(text, "# 1 match for \"THE\""));
    try std.testing.expect(contains(text, "0000  2026-01-01 01:00  [work] shipped the auth fix"));
    try std.testing.expect(!contains(text, "walked the dog"));
    try std.testing.expect(contains(text, "1 more match(es) not shown"));

    // Private content is unmatchable.
    const resp2 = try f.send(allocator, try line(allocator, "8", "tools/call", try allocator.print("{{\"name\":\"search\",\"arguments\":{s}}}", .{"{\"query\":\"PRIVATE-MCP-MARKER\"}"})));
    const text2 = try toolText(allocator, resp2);
    try std.testing.expect(contains(text2, "# 0 matches for \"PRIVATE-MCP-MARKER\""));
    try std.testing.expect(!contains(text2, "PRIVATE-MCP-MARKER-4d7e"));

    // Argument rejections are -32602, not tool errors.
    const resp3 = try f.send(allocator, try line(allocator, "9", "tools/call", try allocator.print("{{\"name\":\"search\",\"arguments\":{s}}}", .{"{\"query\":\"\"}"})));
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(allocator, resp3));
}

test "phase 6: verify_status reports state; corruption is flagged and refused" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-i", false);
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    _ = try f.handshake(allocator, "2025-06-18");

    const status_line = try line(allocator, "10", "tools/call", "{\"name\":\"verify_status\"}");
    const status_resp = try f.send(allocator, status_line);
    const status_text = try toolText(allocator, status_resp);
    try std.testing.expect(contains(status_text, "# zephyr: seq 0..4 head="));
    try std.testing.expect(contains(status_text, "ok: 5 record(s)"));
    try std.testing.expect(contains(status_text, ", 1 redacted"));

    // Corrupt record 0's stored record_hash (the block's leading 32 bytes),
    // the way Phase 4 corrupts the file.
    const seg_name = "2026-01.zph";
    const d = try Dir.openDirAbsolute(io, f.journal.path, .{});
    defer Dir.close(d, io);
    const pristine = try Dir.readFileAlloc(d, io, seg_name, allocator, .unlimited);
    defer allocator.free(pristine);
    var corrupted = try allocator.dupe(u8, pristine);
    corrupted[30 + 3] ^= 0x01;
    try core.segment.writeAtomic(d, io, seg_name, corrupted);

    // verify_status reports the failure (isError, no provenance line).
    const status2_resp = try f.send(allocator, status_line);
    const status2_text = try toolText(allocator, status2_resp);
    try std.testing.expect(contains(status2_text, "FAIL: 2026-01.zph seq 0"));
    try std.testing.expect(!contains(status2_text, "# zephyr:"));
    try std.testing.expect(try isToolError(allocator, status2_resp));

    // Data tools refuse without serving.
    const entries_resp = try f.send(allocator, try line(allocator, "11", "tools/call", try allocator.print("{{\"name\":\"get_entries\",\"arguments\":{s}}}", .{"{\"from\":\"2026-01-01\"}"})));
    const entries_text = try toolText(allocator, entries_resp);
    try std.testing.expect(contains(entries_text, "journal failed verify"));
    try std.testing.expect(contains(entries_text, "FAIL: 2026-01.zph seq 0"));
    try std.testing.expect(!contains(entries_text, "shipped the auth fix"));
    try std.testing.expect(try isToolError(allocator, entries_resp));

    // Restored: ok again.
    try core.segment.writeAtomic(d, io, seg_name, pristine);
    const status3_resp = try f.send(allocator, status_line);
    const status3_text = try toolText(allocator, status3_resp);
    try std.testing.expect(contains(status3_text, "ok: 5 record(s)"));
}

test "phase 6: add_entry is gated; enabled it appends a real entry" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // Default server: add_entry is not a tool (absent from the list, and a
    // call to it is a protocol error the AI cannot work around).
    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-j", false);
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    _ = try f.handshake(allocator, "2025-06-18");
    const resp = try f.send(allocator, try line(allocator, "12", "tools/call", try allocator.print("{{\"name\":\"add_entry\",\"arguments\":{s}}}", .{"{\"text\":\"hello\"}"})));
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(allocator, resp));
    const v = json(allocator, resp);
    try std.testing.expect(contains(v.object.get("error").?.object.get("message").?.string, "unknown tool"));

    // Enabled server: add_entry appends at the current time.
    var w = try FixtureServer.init(allocator, io, ".tmp-phase6-k", true);
    defer w.deinit(allocator);
    try fillFixture(allocator, w.journal);
    _ = try w.handshake(allocator, "2025-06-18");
    const add_resp = try w.send(allocator, try line(allocator, "13", "tools/call", try allocator.print("{{\"name\":\"add_entry\",\"arguments\":{s}}}", .{"{\"text\":\"MCP-WRITE-MARKER-7e2a\",\"tags\":[\"mcp\"]}"})));
    const add_text = try toolText(allocator, add_resp);
    try std.testing.expect(contains(add_text, "logged seq 5"));
    try std.testing.expect(contains(add_text, "# zephyr: seq 0..5 head="));
    try std.testing.expect(!(try isToolError(allocator, add_resp)));

    // The new entry is searchable (search has no date filter).
    const search_resp = try w.send(allocator, try line(allocator, "14", "tools/call", try allocator.print("{{\"name\":\"search\",\"arguments\":{s}}}", .{"{\"query\":\"MCP-WRITE-MARKER\"}"})));
    const search_text = try toolText(allocator, search_resp);
    try std.testing.expect(contains(search_text, "0005  "));
    try std.testing.expect(contains(search_text, "[mcp] MCP-WRITE-MARKER-7e2a"));
}

test "phase 6: get_profile serves the document or its absence" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-l", false);
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    _ = try f.handshake(allocator, "2025-06-18");

    const profile_line = try line(allocator, "15", "tools/call", "{\"name\":\"get_profile\"}");

    // Missing: a note, still with the provenance line, and the notes
    // section (Phase 7) reports its absence in one line.
    const resp = try f.send(allocator, profile_line);
    const text = try toolText(allocator, resp);
    try std.testing.expect(contains(text, "# zephyr: seq 0..4 head="));
    try std.testing.expect(contains(text, "no profile document at profile.md"));
    try std.testing.expect(contains(text, "# notes"));
    try std.testing.expect(contains(text, "(no notes)"));

    // Present: the document content after the provenance line, then the
    // user's notes under a heading.
    const d = try Dir.openDirAbsolute(io, f.journal.path, .{});
    defer Dir.close(d, io);
    var file = try Dir.createFile(d, io, "profile.md", .{});
    try file.writeStreamingAll(io, "# Profile\n- building Zephyr in Zig\n");
    file.close(io);
    var notes_file = try Dir.createFile(d, io, "notes.md", .{});
    try notes_file.writeStreamingAll(io, "I live in Berlin.\n");
    notes_file.close(io);
    const resp2 = try f.send(allocator, profile_line);
    const text2 = try toolText(allocator, resp2);
    try std.testing.expect(contains(text2, "# zephyr: seq 0..4 head="));
    try std.testing.expect(contains(text2, "# Profile"));
    try std.testing.expect(contains(text2, "- building Zephyr in Zig"));
    try std.testing.expect(contains(text2, "# notes"));
    try std.testing.expect(contains(text2, "I live in Berlin."));
}

test "phase 6: json-rpc edge cases over the dispatch" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-m", false);
    defer f.deinit(allocator);
    _ = try f.handshake(allocator, "2025-06-18");

    // Malformed line: parse error with id null; the server keeps going.
    const bad_resp = try f.send(allocator, "this is not json");
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"line is not valid JSON\"}}" ++ "\n",
        bad_resp,
    );

    // String ids are echoed back.
    const str_resp = try f.send(allocator, try line(allocator, "\"abc-1\"", "ping", null));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"abc-1\",\"result\":{}}" ++ "\n", str_resp);

    // Unknown methods are -32601; unknown tools and a missing tool name are
    // -32602 (spec/mcp.md section 2).
    const unk_resp = try f.send(allocator, try line(allocator, "16", "resources/list", null));
    try std.testing.expectEqual(@as(i64, -32601), try rpcErrorCode(allocator, unk_resp));
    const bad_tool_resp = try f.send(allocator, try line(allocator, "17", "tools/call", "{\"name\":\"nope\"}"));
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(allocator, bad_tool_resp));
    const no_name_resp = try f.send(allocator, try line(allocator, "18", "tools/call", "{\"arguments\":{}}"));
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(allocator, no_name_resp));

    // The server survives all of it.
    const alive_resp = try f.send(allocator, try line(allocator, "19", "ping", null));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":19,\"result\":{}}" ++ "\n", alive_resp);
}

test "phase 6: get_digest validates the period" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var f = try FixtureServer.init(allocator, io, ".tmp-phase6-n", false);
    defer f.deinit(allocator);
    try fillFixture(allocator, f.journal);
    _ = try f.handshake(allocator, "2025-06-18");

    const bad_resp = try f.send(allocator, try line(allocator, "20", "tools/call", try allocator.print("{{\"name\":\"get_digest\",\"arguments\":{s}}}", .{"{\"period\":\"year\"}"})));
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(allocator, bad_resp));

    // "week" is accepted; the fixture (2026-01-01) is not in the current
    // week, so the result is the provenance line alone.
    const ok_resp = try f.send(allocator, try line(allocator, "21", "tools/call", try allocator.print("{{\"name\":\"get_digest\",\"arguments\":{s}}}", .{"{\"period\":\"week\"}"})));
    const text = try toolText(allocator, ok_resp);
    try std.testing.expect(contains(text, "# zephyr: seq 0..4 head="));
    try std.testing.expect(!contains(text, "auth fix"));
}
