const std = @import("std");
const mcp_types = @import("../mcp/types.zig");
const json_rpc = @import("../types/json_rpc.zig");
const LspClient = @import("../lsp/client.zig").LspClient;
const DocumentState = @import("../state/documents.zig").DocumentState;
const Workspace = @import("../state/workspace.zig").Workspace;

/// Context passed to every tool handler.
pub const ToolContext = struct {
    lsp_client: *LspClient,
    doc_state: *DocumentState,
    workspace: *const Workspace,
    allocator: std.mem.Allocator,
    allow_command_tools: bool,
    zig_path: ?[]const u8,
    zvm_path: ?[]const u8,
    zls_path: ?[]const u8,
};

/// A tool handler function.
pub const ToolHandler = *const fn (ctx: ToolContext, args: std.json.Value) ToolError![]const u8;

pub const ToolError = error{
    InvalidParams,
    LspError,
    NotConnected,
    RequestTimeout,
    NoResponse,
    FileNotFound,
    FileReadError,
    PathOutsideWorkspace,
    OutOfMemory,
    CommandFailed,
    ZlsNotRunning,
    CommandToolsDisabled,
};

/// Tool registry: maps tool names to handlers and definitions.
pub const Registry = struct {
    entries: std.StringHashMapUnmanaged(Entry),
    allocator: std.mem.Allocator,

    const Entry = struct {
        handler: ToolHandler,
        definition: mcp_types.Tool,
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn register(self: *Registry, name: []const u8, handler: ToolHandler, definition: mcp_types.Tool) !void {
        try self.entries.put(self.allocator, name, .{
            .handler = handler,
            .definition = definition,
        });
    }

    pub fn getHandler(self: *const Registry, name: []const u8) ?ToolHandler {
        if (self.entries.get(name)) |entry| {
            return entry.handler;
        }
        return null;
    }

    /// Get all tool definitions for tools/list.
    pub fn listTools(self: *const Registry, allocator: std.mem.Allocator) ![]const mcp_types.Tool {
        var tools: std.ArrayList(mcp_types.Tool) = .empty;
        errdefer tools.deinit(allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try tools.append(allocator, entry.value_ptr.definition);
        }
        return try tools.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
    }
};

// ── Tests ──

fn dummyHandler(_: ToolContext, _: std.json.Value) ToolError![]const u8 {
    return "ok";
}

fn otherHandler(_: ToolContext, _: std.json.Value) ToolError![]const u8 {
    return "other";
}

test "Registry register and lookup" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    try reg.register("my_tool", dummyHandler, .{
        .name = "my_tool",
        .description = "A test tool",
        .inputSchema = .{},
    });

    const handler = reg.getHandler("my_tool");
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == dummyHandler);
}

test "Registry lookup missing tool returns null" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    try std.testing.expect(reg.getHandler("nonexistent") == null);
}

test "Registry register multiple tools" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    try reg.register("tool_a", dummyHandler, .{
        .name = "tool_a",
        .description = "Tool A",
        .inputSchema = .{},
    });
    try reg.register("tool_b", otherHandler, .{
        .name = "tool_b",
        .description = "Tool B",
        .inputSchema = .{},
    });

    try std.testing.expect(reg.getHandler("tool_a").? == dummyHandler);
    try std.testing.expect(reg.getHandler("tool_b").? == otherHandler);
}

test "Registry listTools returns all definitions" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    try reg.register("alpha", dummyHandler, .{
        .name = "alpha",
        .description = "Alpha tool",
        .inputSchema = .{},
    });
    try reg.register("beta", dummyHandler, .{
        .name = "beta",
        .description = "Beta tool",
        .inputSchema = .{},
    });

    const tools = try reg.listTools(alloc);
    defer alloc.free(tools);
    try std.testing.expectEqual(@as(usize, 2), tools.len);
}

test "Registry empty listTools" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const tools = try reg.listTools(alloc);
    defer alloc.free(tools);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}
