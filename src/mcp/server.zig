const std = @import("std");
const json_rpc = @import("../types/json_rpc.zig");
const mcp_types = @import("types.zig");
const McpTransport = @import("transport.zig").McpTransport;
const Registry = @import("../bridge/registry.zig").Registry;
const ToolContext = @import("../bridge/registry.zig").ToolContext;
const LspClient = @import("../lsp/client.zig").LspClient;
const DocumentState = @import("../state/documents.zig").DocumentState;
const Workspace = @import("../state/workspace.zig").Workspace;
const ZlsProcess = @import("../zls/process.zig").ZlsProcess;

const log = std.log.scoped(.mcp_server);

/// MCP server state machine.
pub const State = enum {
    uninitialized,
    running,
    shutdown,
};

pub const McpServer = struct {
    state: State = .uninitialized,
    transport: *McpTransport,
    registry: *Registry,
    lsp_client: *LspClient,
    doc_state: *DocumentState,
    workspace: *const Workspace,
    allocator: std.mem.Allocator,
    io: std.Io,
    zls_process: ?*ZlsProcess = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: *McpTransport,
        reg: *Registry,
        lsp_client: *LspClient,
        doc_state: *DocumentState,
        workspace: *const Workspace,
    ) McpServer {
        return .{
            .transport = transport,
            .registry = reg,
            .lsp_client = lsp_client,
            .doc_state = doc_state,
            .workspace = workspace,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Main loop: read MCP messages, dispatch, respond.
    pub fn run(self: *McpServer) !void {
        while (self.state != .shutdown) {
            const msg_data = try self.transport.readMessage(self.allocator);
            if (msg_data == null) {
                // stdin EOF — clean shutdown
                break;
            }
            const data = msg_data.?;

            // Use arena for per-request allocation
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            self.handleMessage(arena_alloc, data) catch |err| {
                std.debug.print("[zig-mcp] Error handling message: {}\n", .{err});
                // Try to send error response
                const error_resp = json_rpc.writeError(arena_alloc, null, json_rpc.ErrorCode.internal_error, "Internal error") catch continue;
                self.transport.writeMessage(error_resp) catch {};
            };

            self.allocator.free(data);
        }
    }

    fn handleMessage(self: *McpServer, allocator: std.mem.Allocator, data: []const u8) !void {
        // Parse JSON-RPC message
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
            const resp = try json_rpc.writeError(allocator, null, json_rpc.ErrorCode.parse_error, "Parse error");
            try self.transport.writeMessage(resp);
            return;
        };

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                const resp = try json_rpc.writeError(allocator, null, json_rpc.ErrorCode.invalid_request, "Invalid request");
                try self.transport.writeMessage(resp);
                return;
            },
        };

        // Extract id
        const id: ?json_rpc.RequestId = if (obj.get("id")) |id_val| switch (id_val) {
            .integer => |i| .{ .integer = i },
            .string => |s| .{ .string = s },
            .null => .none,
            else => null,
        } else null;

        // Extract method
        const method = switch (obj.get("method") orelse .null) {
            .string => |s| s,
            else => {
                if (id != null) {
                    const resp = try json_rpc.writeError(allocator, id, json_rpc.ErrorCode.invalid_request, "Missing method");
                    try self.transport.writeMessage(resp);
                }
                return;
            },
        };

        const params = obj.get("params") orelse .null;

        // Dispatch
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(allocator, id);
        } else if (std.mem.eql(u8, method, "notifications/initialized") or std.mem.eql(u8, method, "initialized")) {
            // No response needed
            self.state = .running;
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.state = .shutdown;
            if (id) |rid| {
                const resp = try json_rpc.writeResponse(allocator, rid, null);
                try self.transport.writeMessage(resp);
            }
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try self.handleToolsList(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try self.handleToolsCall(allocator, id, params);
        } else if (std.mem.eql(u8, method, "resources/list")) {
            try self.handleResourcesList(allocator, id);
        } else if (std.mem.eql(u8, method, "ping")) {
            if (id) |rid| {
                const resp = try json_rpc.writeResponse(allocator, rid, .{});
                try self.transport.writeMessage(resp);
            }
        } else {
            // Notifications (no id) are silently ignored
            if (id) |rid| {
                const resp = try json_rpc.writeError(allocator, rid, json_rpc.ErrorCode.method_not_found, "Method not found");
                try self.transport.writeMessage(resp);
            }
        }
    }

    fn handleInitialize(self: *McpServer, allocator: std.mem.Allocator, id: ?json_rpc.RequestId) !void {
        const rid = id orelse return;

        const result = mcp_types.InitializeResult{
            .protocolVersion = "2024-11-05",
            .capabilities = .{
                .tools = .{},
                .resources = .{},
            },
            .serverInfo = .{
                .name = "zig-mcp",
                .version = "0.1.0",
            },
        };

        const resp = try json_rpc.writeResponse(allocator, rid, result);
        try self.transport.writeMessage(resp);
        self.state = .running;
    }

    fn handleToolsList(self: *McpServer, allocator: std.mem.Allocator, id: ?json_rpc.RequestId) !void {
        const rid = id orelse return;
        const tools = try self.registry.listTools(allocator);

        // Build response manually for proper structure
        var aw: std.Io.Writer.Allocating = .init(allocator);
        var jw: std.json.Stringify = .{
            .writer = &aw.writer,
            .options = .{},
        };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try rid.jsonStringify(&jw);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("tools");
        try jw.beginArray();
        for (tools) |tool| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(tool.name);
            try jw.objectField("description");
            try jw.write(tool.description);
            try jw.objectField("inputSchema");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("object");
            try jw.objectField("properties");
            try jw.write(tool.inputSchema.properties);
            if (tool.inputSchema.required) |required| {
                try jw.objectField("required");
                try jw.beginArray();
                for (required) |r| {
                    try jw.write(r);
                }
                try jw.endArray();
            }
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();

        const resp = try aw.toOwnedSlice();
        try self.transport.writeMessage(resp);
    }

    fn handleToolsCall(self: *McpServer, allocator: std.mem.Allocator, id: ?json_rpc.RequestId, params: std.json.Value) !void {
        const rid = id orelse return;

        // Extract tool name and arguments from params
        const params_obj = switch (params) {
            .object => |o| o,
            else => {
                const resp = try json_rpc.writeError(allocator, rid, json_rpc.ErrorCode.invalid_params, "Invalid params");
                try self.transport.writeMessage(resp);
                return;
            },
        };

        const tool_name = switch (params_obj.get("name") orelse .null) {
            .string => |s| s,
            else => {
                const resp = try json_rpc.writeError(allocator, rid, json_rpc.ErrorCode.invalid_params, "Missing tool name");
                try self.transport.writeMessage(resp);
                return;
            },
        };

        const tool_args = params_obj.get("arguments") orelse .null;

        const handler = self.registry.getHandler(tool_name) orelse {
            const resp = try json_rpc.writeError(allocator, rid, json_rpc.ErrorCode.method_not_found, "Unknown tool");
            try self.transport.writeMessage(resp);
            return;
        };

        // Execute tool handler
        const ctx = ToolContext{
            .lsp_client = self.lsp_client,
            .doc_state = self.doc_state,
            .workspace = self.workspace,
            .allocator = allocator,
            .io = self.io,
        };

        const result_text = handler(ctx, tool_args) catch |err| {
            // On connection failure, attempt reconnect + retry once
            if ((err == error.NotConnected or err == error.LspError or err == error.NoResponse) and self.tryReconnectZls()) {
                // Retry with reconnected client
                const retry_text = handler(ctx, tool_args) catch |retry_err| {
                    try self.writeToolError(allocator, rid, retry_err);
                    return;
                };
                try self.writeToolResult(allocator, rid, retry_text, false);
                return;
            }
            try self.writeToolError(allocator, rid, err);
            return;
        };

        try self.writeToolResult(allocator, rid, result_text, false);
    }

    fn writeToolError(self: *McpServer, allocator: std.mem.Allocator, id: json_rpc.RequestId, err: anytype) !void {
        const err_msg = switch (err) {
            error.InvalidParams => "Invalid parameters",
            error.LspError => "LSP error",
            error.NotConnected => "ZLS not connected",
            error.RequestTimeout => "Request timed out",
            error.NoResponse => "No response from ZLS",
            error.FileNotFound => "File not found",
            error.FileReadError => "Could not read file",
            error.CommandFailed => "Command execution failed",
            error.ZlsNotRunning => "ZLS is not running",
            error.OutOfMemory => "Out of memory",
        };
        try self.writeToolResult(allocator, id, err_msg, true);
    }

    fn writeToolResult(self: *McpServer, allocator: std.mem.Allocator, id: json_rpc.RequestId, text: []const u8, is_error: bool) !void {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        var jw: std.json.Stringify = .{
            .writer = &aw.writer,
            .options = .{},
        };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try id.jsonStringify(&jw);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("content");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write(text);
        try jw.endObject();
        try jw.endArray();
        if (is_error) {
            try jw.objectField("isError");
            try jw.write(true);
        }
        try jw.endObject();
        try jw.endObject();

        const resp = try aw.toOwnedSlice();
        try self.transport.writeMessage(resp);
    }

    /// Attempt to reconnect to ZLS after a crash. Returns true on success.
    fn tryReconnectZls(self: *McpServer) bool {
        const zls_proc = self.zls_process orelse return false;

        std.debug.print("[zig-mcp] Attempting ZLS reconnection...\n", .{});

        // Disconnect old LSP session (closes old pipes, joins threads)
        self.lsp_client.disconnect();

        // Respawn ZLS
        const restarted = zls_proc.restart() catch {
            std.debug.print("[zig-mcp] ZLS restart failed\n", .{});
            return false;
        };
        if (!restarted) {
            std.debug.print("[zig-mcp] ZLS max restarts exceeded\n", .{});
            return false;
        }

        // Connect to new pipes
        const zls_stdin = zls_proc.getStdin() orelse return false;
        const zls_stdout = zls_proc.getStdout() orelse return false;
        const zls_stderr = zls_proc.getStderr();

        self.lsp_client.connect(zls_stdin, zls_stdout, zls_stderr) catch {
            std.debug.print("[zig-mcp] Failed to connect to restarted ZLS\n", .{});
            return false;
        };
        zls_proc.detachPipes();

        // Re-initialize LSP session
        const init_response = self.lsp_client.initialize(self.allocator, self.workspace.root_uri) catch {
            std.debug.print("[zig-mcp] LSP re-initialize failed\n", .{});
            return false;
        };
        self.allocator.free(init_response);

        // Reopen tracked documents
        self.doc_state.reopenAll(self.lsp_client);

        std.debug.print("[zig-mcp] ZLS reconnected successfully\n", .{});
        return true;
    }

    fn handleResourcesList(self: *McpServer, allocator: std.mem.Allocator, id: ?json_rpc.RequestId) !void {
        const rid = id orelse return;
        // Return empty resource list for now
        const resp = try json_rpc.writeResponse(allocator, rid, .{ .resources = &[_]u8{} });
        try self.transport.writeMessage(resp);
    }
};

// ── Tests ──

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

const TestSetup = struct {
    server: *McpServer,
    transport: *McpTransport,
    registry: *Registry,
    lsp_client: *LspClient,
    doc_state: *DocumentState,
    workspace: *Workspace,
    read_end: std.Io.File,
    io: std.Io,
    write_end_closed: bool,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !TestSetup {
        const io = testIo();
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.SystemResources;

        const transport = try alloc.create(McpTransport);
        transport.* = .{
            .stdin_file = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .stdout_file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
            .io = io,
        };

        const registry = try alloc.create(Registry);
        registry.* = Registry.init(alloc);

        const lsp_client = try alloc.create(LspClient);
        lsp_client.* = LspClient.init(alloc, io);

        const workspace = try alloc.create(Workspace);
        workspace.* = try Workspace.init(alloc, "/tmp");

        const doc_state = try alloc.create(DocumentState);
        doc_state.* = DocumentState.init(alloc, "/tmp");

        const server = try alloc.create(McpServer);
        server.* = McpServer.init(alloc, io, transport, registry, lsp_client, doc_state, workspace);

        return .{
            .server = server,
            .transport = transport,
            .registry = registry,
            .lsp_client = lsp_client,
            .doc_state = doc_state,
            .workspace = workspace,
            .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .io = io,
            .write_end_closed = false,
            .alloc = alloc,
        };
    }

    /// Close write end and read all response data from pipe.
    fn getResponse(self: *TestSetup) ![]const u8 {
        if (!self.write_end_closed) {
            self.transport.stdout_file.close(self.io);
            self.write_end_closed = true;
        }
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = self.read_end.readStreaming(self.io, &.{buf[total..]}) catch break;
            if (n == 0) break;
            total += n;
        }
        return try self.alloc.dupe(u8, std.mem.trimEnd(u8, buf[0..total], "\n"));
    }

    fn deinit(self: *TestSetup) void {
        if (!self.write_end_closed) self.transport.stdout_file.close(self.io);
        self.read_end.close(self.io);
        self.doc_state.deinit();
        self.alloc.destroy(self.doc_state);
        self.workspace.deinit();
        self.alloc.destroy(self.workspace);
        self.lsp_client.deinit();
        self.alloc.destroy(self.lsp_client);
        self.registry.deinit();
        self.alloc.destroy(self.registry);
        self.alloc.destroy(self.transport);
        self.alloc.destroy(self.server);
    }
};

test "handleMessage initialize" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("2024-11-05", result.get("protocolVersion").?.string);
    const info = result.get("serverInfo").?.object;
    try std.testing.expectEqualStrings("zig-mcp", info.get("name").?.string);
    try std.testing.expectEqual(State.running, ctx.server.state);
}

test "handleMessage ping" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","id":42,"method":"ping"}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    try std.testing.expect(parsed.value.object.get("result") != null);
}

test "handleMessage shutdown" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"shutdown"}
    );

    try std.testing.expectEqual(State.shutdown, ctx.server.state);

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("result") != null);
}

test "notifications/initialized sets state to running" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    try std.testing.expectEqual(State.running, ctx.server.state);
}

test "handleMessage unknown method returns method_not_found" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"nonexistent/method"}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err.get("code").?.integer);
}

test "handleMessage invalid JSON returns parse_error" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc, "not valid json{{{");

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32700), err.get("code").?.integer);
}

test "handleMessage non-object JSON returns invalid_request" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc, "[1,2,3]");

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32600), err.get("code").?.integer);
}

test "handleMessage missing method returns invalid_request" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","id":1}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32600), err.get("code").?.integer);
}

test "handleMessage tools/call unknown tool" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nonexistent"}}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err.get("code").?.integer);
}

test "handleMessage tools/call invalid params" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    defer ctx.deinit();

    try ctx.server.handleMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"not_object"}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32602), err.get("code").?.integer);
}
