const std = @import("std");

/// MCP server capabilities sent during initialize.
pub const ServerCapabilities = struct {
    tools: ?ToolsCapability = null,
    resources: ?ResourcesCapability = null,
};

pub const ToolsCapability = struct {
    listChanged: bool = false,
};

pub const ResourcesCapability = struct {
    subscribe: bool = false,
    listChanged: bool = false,
};

/// MCP InitializeResult.
pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: ServerInfo,
};

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// MCP Tool definition (for tools/list).
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

pub const InputSchema = struct {
    type: []const u8 = "object",
    properties: std.json.Value = .null,
    required: ?[]const []const u8 = null,
};

/// MCP Content types.
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

/// MCP tools/call result.
pub const ToolResult = struct {
    content: []const TextContent,
    isError: ?bool = null,
};

/// MCP Resource definition (for resources/list).
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

/// MCP resource content.
pub const ResourceContent = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

// ── Tests ──

test "makeProperty builds valid schema" {
    const alloc = std.testing.allocator;
    const props = try makeProperty(alloc, .{
        .{ "file", "string", "A file path" },
        .{ "line", "integer", "Line number" },
    });
    defer {
        var obj = props.object;
        var it = obj.iterator();
        while (it.next()) |entry| {
            var inner = entry.value_ptr.object;
            inner.deinit();
        }
        obj.deinit();
    }
    const file_prop = props.object.get("file").?.object;
    try std.testing.expectEqualStrings("string", file_prop.get("type").?.string);
    try std.testing.expectEqualStrings("A file path", file_prop.get("description").?.string);

    const line_prop = props.object.get("line").?.object;
    try std.testing.expectEqualStrings("integer", line_prop.get("type").?.string);
}

test "makeProperty empty fields" {
    const alloc = std.testing.allocator;
    const props = try makeProperty(alloc, .{});
    defer {
        var obj = props.object;
        obj.deinit();
    }
    try std.testing.expectEqual(@as(u32, 0), props.object.count());
}

test "InputSchema default type is object" {
    const schema = InputSchema{};
    try std.testing.expectEqualStrings("object", schema.type);
    try std.testing.expect(schema.required == null);
}

test "Tool JSON serialization" {
    const alloc = std.testing.allocator;
    var tool_props = std.json.ObjectMap.init(alloc);
    defer tool_props.deinit();
    const tool = Tool{
        .name = "zig_test",
        .description = "Run tests",
        .inputSchema = .{
            .properties = .{ .object = tool_props },
        },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.write(tool);
    const json = try aw.toOwnedSlice();
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("zig_test", obj.get("name").?.string);
    try std.testing.expectEqualStrings("Run tests", obj.get("description").?.string);
}

test "ServerCapabilities serialization" {
    const alloc = std.testing.allocator;
    const caps = ServerCapabilities{
        .tools = .{ .listChanged = false },
        .resources = .{ .subscribe = false, .listChanged = false },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.write(caps);
    const json = try aw.toOwnedSlice();
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("tools") != null);
    try std.testing.expect(obj.get("resources") != null);
}

test "InitializeResult serialization" {
    const alloc = std.testing.allocator;
    const result = InitializeResult{
        .protocolVersion = "2024-11-05",
        .capabilities = .{},
        .serverInfo = .{ .name = "test-server", .version = "0.1.0" },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.write(result);
    const json = try aw.toOwnedSlice();
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "2024-11-05") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "test-server") != null);
}

test "TextContent default type is text" {
    const tc = TextContent{ .text = "hello" };
    try std.testing.expectEqualStrings("text", tc.type);
    try std.testing.expectEqualStrings("hello", tc.text);
}

test "ToolResult with error flag" {
    const content = [_]TextContent{.{ .text = "error msg" }};
    const result = ToolResult{
        .content = &content,
        .isError = true,
    };
    try std.testing.expect(result.isError.?);
    try std.testing.expectEqualStrings("error msg", result.content[0].text);
}

/// Helper: Build a property for an input schema.
pub fn makeProperty(allocator: std.mem.Allocator, comptime fields: anytype) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    inline for (fields) |field| {
        var prop = std.json.ObjectMap.init(allocator);
        try prop.put("type", .{ .string = field.@"1" });
        if (@hasField(@TypeOf(field), "2")) {
            try prop.put("description", .{ .string = field.@"2" });
        }
        try obj.put(field.@"0", .{ .object = prop });
    }
    return .{ .object = obj };
}
