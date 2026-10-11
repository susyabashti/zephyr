//! The MCP server: lifecycle, dispatch, and the stdio loop
//! (spec/mcp.md sections 2 and 4). Wire handling lives in protocol.zig;
//! tool semantics in tools.zig.

const std = @import("std");
const core = @import("zephyr_core");
const journal_mod = core.journal;
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");

const Io = std.Io;

const Allocator = std.mem.Allocator;

// The server is single-threaded, and a line must stay valid while its
// response is being written, so the loop buffers are file-scope globals.
var in_buf: [protocol.MaxLineLen]u8 = undefined;
var out_buf: [1 << 16]u8 = undefined;

pub const HandleError = Allocator.Error || Io.Writer.Error;
pub const RunError = Io.Reader.Error || Io.Writer.Error || Io.File.Writer.Error || Allocator.Error;

/// ServerInfo version. Keep in sync with cli.Version (one binary, one
/// version).
pub const Version: []const u8 = "0.2.0";

/// The protocol versions this server speaks (spec/mcp.md section 2).
pub const LatestProtocolVersion: []const u8 = "2025-06-18";
pub const OlderProtocolVersion: []const u8 = "2025-03-26";

const instructions =
    "Read-only access to a Zephyr tamper-evident journal. Every successful " ++
    "result begins with a provenance line (# zephyr: seq 0..N head=HEX) " ++
    "describing the verified log state it was read from. A result with " ++
    "isError=true means the journal failed verification: do not use " ++
    "stale or unverified data. " ++
    "Prefer get_digest over scanning raw entries.";

pub const Server = struct {
    journal: *const journal_mod.Journal,
    allow_write: bool,
    /// The client has sent notifications/initialized.
    initialized: bool = false,
    /// The initialize request has been handled.
    handshake_done: bool = false,

    pub fn init(journal: *const journal_mod.Journal, allow_write: bool) Server {
        return .{ .journal = journal, .allow_write = allow_write };
    }

    /// Handles one newline-delimited line, writing the single response to
    /// `out` when the message is a request. Notifications produce no
    /// response. The line borrows from the reader; nothing here retains it.
    pub fn handleLine(self: *Server, arena: Allocator, io: Io, line: []const u8, out: *Io.Writer) HandleError!void {
        const env = protocol.parseEnvelope(arena, line) catch |err| {
            const failure = protocol.parseFailure(err);
            return protocol.writeError(arena, out, null, failure.code, failure.message);
        };
        if (env.id == null) {
            // Notification: no response, ever.
            if (std.mem.eql(u8, env.method, "notifications/initialized")) self.initialized = true;
            return;
        }
        const id = env.id.?;
        if (std.mem.eql(u8, env.method, "initialize")) {
            if (self.handshake_done) {
                return protocol.writeError(arena, out, id, protocol.RpcCode.invalid_request, "already initialized");
            }
            return self.handleInitialize(arena, out, id, env.params);
        }
        if (std.mem.eql(u8, env.method, "ping")) {
            return protocol.writeResult(out, id, "{}");
        }
        if (!self.initialized) {
            return protocol.writeError(arena, out, id, protocol.RpcCode.invalid_request, "request before initialization completed");
        }
        if (std.mem.eql(u8, env.method, "tools/list")) {
            return self.handleToolsList(arena, out, id);
        }
        if (std.mem.eql(u8, env.method, "tools/call")) {
            return self.handleToolsCall(arena, io, out, id, env.params);
        }
        return protocol.writeError(arena, out, id, protocol.RpcCode.method_not_found, "method not found");
    }

    /// Runs the stdio loop until stdin reaches EOF (spec/mcp.md section 2).
    /// stdout carries protocol messages only; the loop terminates on EOF,
    /// when the client closes the input stream.
    pub fn run(self: *Server, allocator: Allocator, io: Io) RunError!void {
        const stdin = Io.File.stdin();
        const stdout = Io.File.stdout();
        var reader = Io.File.reader(stdin, io, &in_buf);
        // Streaming writes: every protocol message hits the fd immediately.
        var writer = Io.File.writerStreaming(stdout, io, &out_buf);
        while (true) {
            const line = readNextLine(allocator, &reader.interface) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| return e,
            };
            if (line == null) break;
            const l = line.?;
            defer allocator.free(l.bytes);
            if (l.too_long) {
                try protocol.writeError(
                    allocator,
                    &writer.interface,
                    null,
                    protocol.RpcCode.parse_error,
                    "message exceeds the 1 MiB line limit",
                );
                try Io.File.Writer.flush(&writer);
                continue;
            }
            var text = l.bytes;
            if (std.mem.endsWith(u8, text, "\r")) text = text[0 .. text.len - 1]; // tolerate CRLF
            if (text.len == 0) continue;
            try self.handleLine(allocator, io, text, &writer.interface);
            // The protocol is interactive: a response must reach the
            // fd before the client sends the next request.
            try Io.File.Writer.flush(&writer);
        }
    }

    // ---------------------------------------------------------------- dispatch

    fn handleInitialize(self: *Server, arena: Allocator, out: *Io.Writer, id: protocol.Value, params: ?protocol.Value) HandleError!void {
        self.handshake_done = true;
        const requested = requestedVersion(params);
        const version = if (requested) |r|
            if (isSupportedVersion(r)) r else LatestProtocolVersion
        else
            LatestProtocolVersion;
        const result = try arena.print(initialize_fmt, .{ version, Version, instructions });
        return protocol.writeResult(out, id, result);
    }

    fn handleToolsList(self: *Server, arena: Allocator, out: *Io.Writer, id: protocol.Value) HandleError!void {
        const defs = tools.list(self.allow_write);
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(arena);
        try result.appendSlice(arena, "{\"tools\":[");
        for (defs, 0..) |tool, i| {
            if (i > 0) try result.append(arena, ',');
            try result.appendSlice(arena, "{\"name\":\"");
            try result.appendSlice(arena, tool.name);
            try result.appendSlice(arena, "\",\"description\":\"");
            try result.appendSlice(arena, tool.description);
            try result.appendSlice(arena, "\",\"inputSchema\":");
            try result.appendSlice(arena, tool.input_schema);
            try result.append(arena, '}');
        }
        try result.appendSlice(arena, "]}");
        return protocol.writeResult(out, id, result.items);
    }

    fn handleToolsCall(self: *Server, arena: Allocator, io: Io, out: *Io.Writer, id: protocol.Value, params: ?protocol.Value) HandleError!void {
        // params: {"name": <string>, "arguments": <object, optional>}
        var tool_name: ?[]const u8 = null;
        var arguments: ?protocol.Value = null;
        if (params) |p| {
            if (p != .object) {
                return protocol.writeError(arena, out, id, protocol.RpcCode.invalid_params, "params must be an object");
            }
            if (p.object.get("name")) |v| {
                if (v != .string) {
                    return protocol.writeError(arena, out, id, protocol.RpcCode.invalid_params, "tool name must be a string");
                }
                tool_name = v.string;
            }
            arguments = p.object.get("arguments");
        }
        const name = tool_name orelse {
            return protocol.writeError(arena, out, id, protocol.RpcCode.invalid_params, "missing tool name");
        };
        const today_day = self.todayDay(io) catch |err| {
            try protocol.writeError(arena, out, id, protocol.RpcCode.internal_error, try arena.print("internal error: {s}", .{@errorName(err)}));
            return;
        };
        const call = tools.validate(arena, self.allow_write, name, arguments, today_day) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                return protocol.writeError(arena, out, id, protocol.RpcCode.invalid_params, try rejectMessage(arena, e, name));
            },
        };
        const outcome = tools.execute(arena, io, self.journal, call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                return writeToolResult(arena, out, id, try arena.print("tool execution failed: {s}", .{@errorName(e)}), true);
            },
        };
        return writeToolResult(arena, out, id, outcome.text, outcome.is_error);
    }

    /// Today's civil day in the journal's timezone (feeds get_digest).
    fn todayDay(self: *const Server, io: Io) (core.timezone.LoadError || error{ TzOutOfRange, TimestampOutOfRange })!i64 {
        const now_ms: i64 = Io.Timestamp.now(io, .real).toMilliseconds();
        if (now_ms < 0) return error.TimestampOutOfRange;
        const ts: u64 = @intCast(now_ms);
        const tz_offset_min = try self.journal.tzOffsetMinutesAtMs(ts);
        return core.view.localDay(ts, tz_offset_min);
    }
};

const initialize_fmt = "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"zephyr\",\"version\":\"{s}\"}},\"instructions\":\"{s}\"}}";

/// The requested protocol version, if params carry one as a string.
fn requestedVersion(params: ?protocol.Value) ?[]const u8 {
    if (params) |p| {
        if (p != .object) return null;
        const v = p.object.get("protocolVersion") orelse return null;
        if (v == .string) return v.string;
    }
    return null;
}

fn isSupportedVersion(version: []const u8) bool {
    return std.mem.eql(u8, version, LatestProtocolVersion) or
        std.mem.eql(u8, version, OlderProtocolVersion);
}

fn writeToolResult(arena: Allocator, out: *Io.Writer, id: protocol.Value, text: []const u8, is_error: bool) HandleError!void {
    const result_json = try protocol.toolResultJson(arena, text, is_error);
    return protocol.writeResult(out, id, result_json);
}

/// The -32602 message for a rejected tool call (spec/mcp.md sections 2 and 5).
fn rejectMessage(allocator: Allocator, err: tools.RejectError, name: []const u8) Allocator.Error![]const u8 {
    return switch (err) {
        error.UnknownTool => allocator.print("unknown tool: {s}", .{name}),
        error.WriteDisabled => allocator.print("unknown tool: add_entry (write access disabled; start the server with --allow-write)", .{}),
        else => |e| allocator.print("invalid arguments: {s}", .{@errorName(e)}),
    };
}

const Line = struct {
    bytes: []u8,
    too_long: bool,
};

/// Reads one newline-terminated line (a final line may lack the newline).
/// Returns null at clean EOF. Lines over MaxLineLen are read through to the
/// end but flagged, so one oversized line costs one parse error, not a
/// stream of them.
fn readNextLine(allocator: Allocator, reader: *Io.Reader) (Io.Reader.Error || Allocator.Error)!?Line {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);
    var too_long = false;
    var saw_byte = false;
    while (true) {
        const b = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        saw_byte = true;
        if (b == '\n') break;
        if (too_long) continue;
        if (line.items.len == protocol.MaxLineLen) {
            too_long = true;
            continue;
        }
        try line.append(allocator, b);
    }
    if (!saw_byte) return null;
    const bytes = try line.toOwnedSlice(allocator);
    errdefer allocator.free(bytes);
    return Line{ .bytes = bytes, .too_long = too_long };
}
