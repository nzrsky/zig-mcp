const std = @import("std");

/// JSON-RPC 2.0 request ID — can be integer, string, or null.
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    none,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !RequestId {
        _ = allocator;
        _ = options;
        const token = try source.next();
        return switch (token) {
            .number => |n| .{ .integer = std.fmt.parseInt(i64, n, 10) catch return .{ .string = n } },
            .string, .allocated_string => |s| .{ .string = s },
            .null => .none,
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonStringify(self: RequestId, jw: anytype) !void {
        switch (self) {
            .integer => |i| try jw.write(i),
            .string => |s| try jw.write(s),
            .none => try jw.write(null),
        }
    }

    pub fn eql(a: RequestId, b: RequestId) bool {
        return switch (a) {
            .integer => |ai| switch (b) {
                .integer => |bi| ai == bi,
                else => false,
            },
            .string => |as_| switch (b) {
                .string => |bs| std.mem.eql(u8, as_, bs),
                else => false,
            },
            .none => switch (b) {
                .none => true,
                else => false,
            },
        };
    }
};

/// Raw JSON-RPC message parsed from the wire. We keep `params`/`result`/`error`
/// as raw JSON slices so each handler can parse them with the right types.
pub const Message = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?ErrorObject = null,
};

pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// Standard JSON-RPC error codes.
pub const ErrorCode = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    // MCP/LSP custom
    pub const server_not_initialized: i64 = -32002;
    pub const request_timeout: i64 = -32001;
    pub const zls_not_running: i64 = -32000;
};

/// Write a JSON-RPC response with the given ID and result value.
pub fn writeResponse(allocator: std.mem.Allocator, id: RequestId, result: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try RequestId.jsonStringify(id, &jw);
    try jw.objectField("result");
    try jw.write(result);
    try jw.endObject();
    return try aw.toOwnedSlice();
}

/// Write a JSON-RPC error response.
pub fn writeError(allocator: std.mem.Allocator, id: ?RequestId, code: i64, message: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    if (id) |rid| {
        try rid.jsonStringify(&jw);
    } else {
        try jw.write(null);
    }
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(code);
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    try jw.endObject();
    return try aw.toOwnedSlice();
}

/// Write a JSON-RPC notification (no id).
pub fn writeNotification(allocator: std.mem.Allocator, method: []const u8, params: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write(method);
    try jw.objectField("params");
    try jw.write(params);
    try jw.endObject();
    return try aw.toOwnedSlice();
}

// ── Tests ──

test "RequestId integer equality" {
    const a = RequestId{ .integer = 42 };
    const b = RequestId{ .integer = 42 };
    const c = RequestId{ .integer = 99 };
    try std.testing.expect(RequestId.eql(a, b));
    try std.testing.expect(!RequestId.eql(a, c));
}

test "RequestId string equality" {
    const a = RequestId{ .string = "abc" };
    const b = RequestId{ .string = "abc" };
    const c = RequestId{ .string = "xyz" };
    try std.testing.expect(RequestId.eql(a, b));
    try std.testing.expect(!RequestId.eql(a, c));
}

test "RequestId none equality" {
    const a = RequestId.none;
    const b = RequestId.none;
    try std.testing.expect(RequestId.eql(a, b));
}

test "RequestId cross-type inequality" {
    const int_id = RequestId{ .integer = 1 };
    const str_id = RequestId{ .string = "1" };
    const none_id = RequestId.none;
    try std.testing.expect(!RequestId.eql(int_id, str_id));
    try std.testing.expect(!RequestId.eql(int_id, none_id));
    try std.testing.expect(!RequestId.eql(str_id, none_id));
}

test "RequestId integer JSON serialization" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const id = RequestId{ .integer = 42 };
    try RequestId.jsonStringify(id, &jw);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "RequestId string JSON serialization" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const id = RequestId{ .string = "req-1" };
    try RequestId.jsonStringify(id, &jw);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\"req-1\"", out);
}

test "RequestId none JSON serialization" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const id = RequestId.none;
    try RequestId.jsonStringify(id, &jw);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "writeResponse with integer id" {
    const alloc = std.testing.allocator;
    const resp = try writeResponse(alloc, .{ .integer = 1 }, "hello");
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("hello", obj.get("result").?.string);
}

test "writeResponse with null result" {
    const alloc = std.testing.allocator;
    const resp = try writeResponse(alloc, .{ .integer = 5 }, null);
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("result").? == .null);
}

test "writeError produces valid JSON-RPC error" {
    const alloc = std.testing.allocator;
    const resp = try writeError(alloc, .{ .integer = 7 }, ErrorCode.method_not_found, "not found");
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 7), obj.get("id").?.integer);
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("not found", err_obj.get("message").?.string);
}

test "writeError with null id" {
    const alloc = std.testing.allocator;
    const resp = try writeError(alloc, null, ErrorCode.parse_error, "bad json");
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("id").? == .null);
}

test "writeNotification has no id field" {
    const alloc = std.testing.allocator;
    const notif = try writeNotification(alloc, "textDocument/didOpen", .{ .uri = "file:///a.zig" });
    defer alloc.free(notif);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, notif, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("id") == null);
    try std.testing.expectEqualStrings("textDocument/didOpen", obj.get("method").?.string);
    const params = obj.get("params").?.object;
    try std.testing.expectEqualStrings("file:///a.zig", params.get("uri").?.string);
}

test "writeRequest has id and method" {
    const alloc = std.testing.allocator;
    const req = try writeRequest(alloc, .{ .integer = 10 }, "textDocument/hover", .{ .line = @as(i64, 5) });
    defer alloc.free(req);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, req, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 10), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("textDocument/hover", obj.get("method").?.string);
    try std.testing.expect(obj.get("params") != null);
}

test "ErrorCode constants" {
    try std.testing.expectEqual(@as(i64, -32700), ErrorCode.parse_error);
    try std.testing.expectEqual(@as(i64, -32600), ErrorCode.invalid_request);
    try std.testing.expectEqual(@as(i64, -32601), ErrorCode.method_not_found);
    try std.testing.expectEqual(@as(i64, -32602), ErrorCode.invalid_params);
    try std.testing.expectEqual(@as(i64, -32603), ErrorCode.internal_error);
}

/// Write a JSON-RPC request (with id).
pub fn writeRequest(allocator: std.mem.Allocator, id: RequestId, method: []const u8, params: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try RequestId.jsonStringify(id, &jw);
    try jw.objectField("method");
    try jw.write(method);
    try jw.objectField("params");
    try jw.write(params);
    try jw.endObject();
    return try aw.toOwnedSlice();
}
