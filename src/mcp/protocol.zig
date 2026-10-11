//! MCP wire protocol (spec/mcp.md section 2): newline-delimited JSON-RPC 2.0.
//!
//! Pure layer: parses one incoming line and builds one outgoing response.
//! Lifecycle is owned by server.zig; tool data by tools.zig. No I/O happens
//! here beyond writing into a caller-supplied writer.

const std = @import("std");
const Io = std.Io;

const Allocator = std.mem.Allocator;

/// Maximum size of one line the server will accept (spec/mcp.md section 2).
pub const MaxLineLen: usize = 1 << 20;

/// A decoded JSON value (borrowed from the parse allocation).
pub const Value = std.json.Value;

pub const RpcCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

/// One client message: a request (has an id) or a notification (no id).
/// Fields borrow from the parsed value tree owned by the caller allocator.
pub const Envelope = struct {
    id: ?Value,
    method: []const u8,
    params: ?Value,
};

pub const ParseEnvelopeError = error{
    /// The line is not valid JSON.
    MalformedJson,
    /// The line is valid JSON but not a JSON-RPC object.
    NotObject,
    /// The jsonrpc field is missing or not the string 2.0.
    BadJsonrpc,
    /// The method field is missing or not a string.
    BadMethod,
    /// The id field is present but not a string or integer.
    BadId,
} || Allocator.Error;

/// Parses one newline-delimited JSON-RPC line into an envelope.
pub fn parseEnvelope(allocator: Allocator, line: []const u8) ParseEnvelopeError!Envelope {
    const value = std.json.parseFromSliceLeaky(Value, allocator, line, .{}) catch return error.MalformedJson;
    const obj = if (value == .object) value.object else return error.NotObject;
    const jsonrpc = obj.get("jsonrpc") orelse return error.BadJsonrpc;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) return error.BadJsonrpc;
    const method = obj.get("method") orelse return error.BadMethod;
    if (method != .string) return error.BadMethod;
    const id = obj.get("id");
    if (id) |v| {
        switch (v) {
            .string, .integer => {},
            else => return error.BadId,
        }
    }
    return Envelope{ .id = id, .method = method.string, .params = obj.get("params") };
}

pub const RpcFailure = struct {
    code: i32,
    message: []const u8,
};

/// Maps a structural parse failure to its JSON-RPC error (id null).
pub fn parseFailure(err: ParseEnvelopeError) RpcFailure {
    return switch (err) {
        error.MalformedJson => .{ .code = RpcCode.parse_error, .message = "line is not valid JSON" },
        error.NotObject => .{ .code = RpcCode.invalid_request, .message = "expected a JSON object" },
        error.BadJsonrpc => .{ .code = RpcCode.invalid_request, .message = "jsonrpc field must be the string 2.0" },
        error.BadMethod => .{ .code = RpcCode.invalid_request, .message = "method field must be a string" },
        error.BadId => .{ .code = RpcCode.invalid_request, .message = "id must be a string or integer" },
        error.OutOfMemory => .{ .code = RpcCode.internal_error, .message = "out of memory" },
    };
}

pub const WriteError = Io.Writer.Error;

const result_head = "{\"jsonrpc\":\"2.0\",\"id\":";
const result_mid = ",\"result\":";
const error_code_mid = ",\"error\":{\"code\":";
const error_message_mid = ",\"message\":";
const error_tail = "}}";

/// Writes the result envelope and a newline (spec/mcp.md section 2).
pub fn writeResult(writer: *Io.Writer, id: ?Value, result_json: []const u8) WriteError!void {
    try writeHead(writer, id);
    try Io.Writer.writeAll(writer, result_mid);
    try Io.Writer.writeAll(writer, result_json);
    try Io.Writer.writeAll(writer, "}\n");
}

/// Writes the error envelope and a newline.
pub fn writeError(
    allocator: Allocator,
    writer: *Io.Writer,
    id: ?Value,
    code: i32,
    message: []const u8,
) (WriteError || Allocator.Error)!void {
    try writeHead(writer, id);
    try Io.Writer.writeAll(writer, error_code_mid);
    try Io.Writer.print(writer, "{d}", .{code});
    try Io.Writer.writeAll(writer, error_message_mid);
    const escaped = try std.json.Stringify.valueAlloc(allocator, Value{ .string = message }, .{});
    try Io.Writer.writeAll(writer, escaped);
    try Io.Writer.writeAll(writer, error_tail ++ "\n");
}

const tool_head = "{\"content\":[{\"type\":\"text\",\"text\":";
const tool_tail_ok = "}]}";
const tool_tail_err = "}],\"isError\":true}";

/// Builds the JSON object for a tool result: a single text content item,
/// gaining the isError flag when execution failed (spec/mcp.md section 5).
pub fn toolResultJson(allocator: Allocator, text: []const u8, is_error: bool) (WriteError || Allocator.Error)![]u8 {
    const tail = if (is_error) tool_tail_err else tool_tail_ok;
    const escaped = try std.json.Stringify.valueAlloc(allocator, Value{ .string = text }, .{});
    const out = try allocator.alloc(u8, tool_head.len + escaped.len + tail.len);
    errdefer allocator.free(out);
    var w: usize = 0;
    @memcpy(out[w .. w + tool_head.len], tool_head);
    w += tool_head.len;
    @memcpy(out[w .. w + escaped.len], escaped);
    w += escaped.len;
    @memcpy(out[w .. w + tail.len], tail);
    return out;
}

fn writeHead(writer: *Io.Writer, id: ?Value) WriteError!void {
    try Io.Writer.writeAll(writer, result_head);
    if (id == null) {
        return Io.Writer.writeAll(writer, "null");
    }
    return std.json.Stringify.value(id.?, .{}, writer);
}

const req_fixture = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{\"cursor\":\"x\"}}";
const notify_fixture = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
const str_id_fixture = "{\"jsonrpc\":\"2.0\",\"id\":\"abc-1\",\"method\":\"ping\"}";
const no_jsonrpc_fixture = "{\"id\":1,\"method\":\"ping\"}";
const old_jsonrpc_fixture = "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}";
const no_method_fixture = "{\"jsonrpc\":\"2.0\",\"id\":1}";
const bad_id_fixture = "{\"jsonrpc\":\"2.0\",\"id\":[1],\"method\":\"ping\"}";

test "parseEnvelope: request, notification, and failures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const req = try parseEnvelope(allocator, req_fixture);
    try std.testing.expect(req.id != null);
    try std.testing.expectEqual(@as(i64, 7), req.id.?.integer);
    try std.testing.expectEqualStrings("tools/list", req.method);
    try std.testing.expect(req.params != null);

    const notify = try parseEnvelope(allocator, notify_fixture);
    try std.testing.expect(notify.id == null);
    try std.testing.expectEqualStrings("notifications/initialized", notify.method);
    try std.testing.expect(notify.params == null);

    const str_id = try parseEnvelope(allocator, str_id_fixture);
    try std.testing.expectEqualStrings("abc-1", str_id.id.?.string);

    try std.testing.expectError(error.MalformedJson, parseEnvelope(allocator, "not json"));
    try std.testing.expectError(error.NotObject, parseEnvelope(allocator, "[1,2]"));
    try std.testing.expectError(error.NotObject, parseEnvelope(allocator, "\"a plain string\""));
    try std.testing.expectError(error.BadJsonrpc, parseEnvelope(allocator, no_jsonrpc_fixture));
    try std.testing.expectError(error.BadJsonrpc, parseEnvelope(allocator, old_jsonrpc_fixture));
    try std.testing.expectError(error.BadMethod, parseEnvelope(allocator, no_method_fixture));
    try std.testing.expectError(error.BadId, parseEnvelope(allocator, bad_id_fixture));
}

test "parseFailure maps every member" {
    try std.testing.expectEqual(@as(i32, -32700), parseFailure(error.MalformedJson).code);
    try std.testing.expectEqual(@as(i32, -32600), parseFailure(error.NotObject).code);
    try std.testing.expectEqual(@as(i32, -32600), parseFailure(error.BadJsonrpc).code);
    try std.testing.expectEqual(@as(i32, -32600), parseFailure(error.BadMethod).code);
    try std.testing.expectEqual(@as(i32, -32600), parseFailure(error.BadId).code);
    try std.testing.expectEqual(@as(i32, -32603), parseFailure(error.OutOfMemory).code);
}

const escaped_ok_expected = "{\"content\":[{\"type\":\"text\",\"text\":\"line1\\nline2 \\\"quoted\\\"\"}]}";
const escaped_err_expected = "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}";

test "toolResultJson escapes text and flags errors" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ok = try toolResultJson(allocator, "line1\nline2 \"quoted\"", false);
    defer allocator.free(ok);
    try std.testing.expectEqualStrings(escaped_ok_expected, ok);

    const err = try toolResultJson(allocator, "boom", true);
    defer allocator.free(err);
    try std.testing.expectEqualStrings(escaped_err_expected, err);
}

const result_line_expected = "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"ok\":true}}";
const error_line_expected = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32602,\"message\":\"bad \\\"args\\\"\"}}";

test "writeResult and writeError produce one JSON object per line" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);

    const id = try std.json.parseFromSliceLeaky(Value, allocator, "42", .{});
    try writeResult(&writer, id, "{\"ok\":true}");
    try std.testing.expectEqualStrings(result_line_expected ++ "\n", writer.buffered());

    var buf2: [256]u8 = undefined;
    var writer2: Io.Writer = .fixed(&buf2);
    try writeError(allocator, &writer2, null, -32602, "bad \"args\"");
    try std.testing.expectEqualStrings(error_line_expected ++ "\n", writer2.buffered());
}
