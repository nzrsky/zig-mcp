const std = @import("std");
const json_rpc = @import("../types/json_rpc.zig");
const mcp_types = @import("types.zig");
const McpTransport = @import("transport.zig").McpTransport;
const Registry = @import("../bridge/registry.zig").Registry;
const ToolContext = @import("../bridge/registry.zig").ToolContext;
const ToolError = @import("../bridge/registry.zig").ToolError;
const LspClient = @import("../lsp/client.zig").LspClient;
const DocumentState = @import("../state/documents.zig").DocumentState;
const Workspace = @import("../state/workspace.zig").Workspace;
const ZlsProcess = @import("../zls/process.zig").ZlsProcess;
const testing = @import("../testing.zig");

/// MCP server state machine.
pub const State = enum {
    uninitialized,
    running,
    shutdown,
};

pub const protocol_version = "2024-11-05";
pub const server_version = "0.2.0";

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
            const msg_data = (try self.transport.readMessage(self.allocator)) orelse break; // stdin EOF
            defer self.allocator.free(msg_data);

            // Use arena for per-request allocation
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            self.handleMessage(arena_alloc, msg_data) catch |err| {
                std.debug.print("[zig-mcp] Error handling message: {s}\n", .{@errorName(err)});
                const error_resp = json_rpc.writeError(arena_alloc, null, json_rpc.ErrorCode.internal_error, "Internal error") catch continue;
                // A failed write means stdout is gone; there is no way to
                // report anything after that, so stop rather than spin.
                self.transport.writeMessage(error_resp) catch break;
            };
        }
    }

    /// Write one response and release it. Keeps every caller allocator-agnostic
    /// instead of relying on a request arena to mop up.
    fn send(self: *McpServer, allocator: std.mem.Allocator, resp: []const u8) !void {
        defer allocator.free(resp);
        try self.transport.writeMessage(resp);
    }

    fn sendError(
        self: *McpServer,
        allocator: std.mem.Allocator,
        id: ?json_rpc.RequestId,
        code: i64,
        message: []const u8,
    ) !void {
        try self.send(allocator, try json_rpc.writeError(allocator, id, code, message));
    }

    fn handleMessage(self: *McpServer, allocator: std.mem.Allocator, data: []const u8) !void {
        // Parse JSON-RPC message
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
            try self.sendError(allocator, null, json_rpc.ErrorCode.parse_error, "Parse error");
            return;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                try self.sendError(allocator, null, json_rpc.ErrorCode.invalid_request, "Invalid request");
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
                    try self.sendError(allocator, id, json_rpc.ErrorCode.invalid_request, "Missing method");
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
                try self.send(allocator, try json_rpc.writeResponse(allocator, rid, null));
            }
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try self.handleToolsList(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try self.handleToolsCall(allocator, id, params);
        } else if (std.mem.eql(u8, method, "resources/list")) {
            try self.handleResourcesList(allocator, id);
        } else if (std.mem.eql(u8, method, "ping")) {
            if (id) |rid| {
                try self.send(allocator, try json_rpc.writeResponse(allocator, rid, .{}));
            }
        } else {
            // Notifications (no id) are silently ignored
            if (id) |rid| {
                try self.sendError(allocator, rid, json_rpc.ErrorCode.method_not_found, "Method not found");
            }
        }
    }

    fn handleInitialize(self: *McpServer, allocator: std.mem.Allocator, id: ?json_rpc.RequestId) !void {
        const rid = id orelse return;

        const result = mcp_types.InitializeResult{
            .protocolVersion = protocol_version,
            .capabilities = .{
                .tools = .{},
                .resources = .{},
            },
            .serverInfo = .{
                .name = "zig-mcp",
                .version = server_version,
            },
        };

        try self.send(allocator, try json_rpc.writeResponse(allocator, rid, result));
        self.state = .running;
    }

    fn handleToolsList(self: *McpServer, allocator: std.mem.Allocator, id: ?json_rpc.RequestId) !void {
        const rid = id orelse return;
        const tools = try self.registry.listTools(allocator);
        defer allocator.free(tools);

        // Built by hand so the schema shape matches what MCP clients expect.
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
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

        try self.transport.writeMessage(aw.written());
    }

    fn handleToolsCall(self: *McpServer, allocator: std.mem.Allocator, id: ?json_rpc.RequestId, params: std.json.Value) !void {
        const rid = id orelse return;

        // Extract tool name and arguments from params
        const params_obj = switch (params) {
            .object => |o| o,
            else => {
                try self.sendError(allocator, rid, json_rpc.ErrorCode.invalid_params, "Invalid params");
                return;
            },
        };

        const tool_name = switch (params_obj.get("name") orelse .null) {
            .string => |s| s,
            else => {
                try self.sendError(allocator, rid, json_rpc.ErrorCode.invalid_params, "Missing tool name");
                return;
            },
        };

        const tool_args = params_obj.get("arguments") orelse .null;

        const handler = self.registry.getHandler(tool_name) orelse {
            try self.sendError(allocator, rid, json_rpc.ErrorCode.method_not_found, "Unknown tool");
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
            if (isConnectionError(err) and self.tryReconnectZls()) {
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

    fn isConnectionError(err: ToolError) bool {
        return switch (err) {
            error.NotConnected, error.LspError, error.NoResponse, error.ZlsNotRunning => true,
            else => false,
        };
    }

    fn writeToolError(self: *McpServer, allocator: std.mem.Allocator, id: json_rpc.RequestId, err: ToolError) !void {
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
        defer aw.deinit();
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

        try self.transport.writeMessage(aw.written());
    }

    /// Attempt to reconnect to ZLS after a crash. Returns true on success.
    fn tryReconnectZls(self: *McpServer) bool {
        const zls_proc = self.zls_process orelse return false;

        std.debug.print("[zig-mcp] Attempting ZLS reconnection...\n", .{});

        // Kill first, disconnect second. Closing pipes under a reader thread
        // that is still blocked on them would neither wake it nor free the
        // descriptor before the respawn claims the same numbers.
        zls_proc.kill();
        self.lsp_client.disconnect();

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
        // `resources` must be a JSON array. An empty `[]const u8` would
        // serialize as the string "", which clients reject.
        const empty: []const mcp_types.Resource = &.{};
        try self.send(allocator, try json_rpc.writeResponse(allocator, rid, .{ .resources = empty }));
    }
};

// ── Tests ──

const TestSetup = struct {
    server: McpServer,
    transport: McpTransport,
    registry: Registry,
    lsp_client: LspClient,
    doc_state: DocumentState,
    workspace: Workspace,
    read_end: std.Io.File,
    write_end: std.Io.File,
    write_end_closed: bool = false,
    alloc: std.mem.Allocator,

    /// Two-phase like the other fixtures: `McpServer` stores pointers into this
    /// struct, so it can only be built once the struct is at its final address.
    fn init(alloc: std.mem.Allocator) !TestSetup {
        const p = try testing.Pipe.open();
        return .{
            // SAFETY: assigned by `start`, which every test calls before
            // touching the server. It cannot be built here because it
            // stores pointers into this struct.
            .server = undefined,
            .transport = .{
                .stdin_file = p.read_end,
                .stdout_file = p.write_end,
                .io = testing.io(),
            },
            .registry = Registry.init(alloc),
            .lsp_client = LspClient.init(alloc, testing.io()),
            .doc_state = DocumentState.init(alloc, "/tmp", testing.io()),
            .workspace = try Workspace.init(alloc, "/tmp"),
            .read_end = p.read_end,
            .write_end = p.write_end,
            .alloc = alloc,
        };
    }

    fn start(self: *TestSetup) void {
        self.server = McpServer.init(
            self.alloc,
            testing.io(),
            &self.transport,
            &self.registry,
            &self.lsp_client,
            &self.doc_state,
            &self.workspace,
        );
    }

    fn handle(self: *TestSetup, message: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        try self.server.handleMessage(arena.allocator(), message);
    }

    /// Close write end and read all response data from pipe.
    fn getResponse(self: *TestSetup) ![]const u8 {
        if (!self.write_end_closed) {
            self.write_end.close(testing.io());
            self.write_end_closed = true;
        }
        var buf: [8192]u8 = undefined;
        const data = try testing.readAll(self.read_end, &buf);
        return self.alloc.dupe(u8, std.mem.trimEnd(u8, data, "\n"));
    }

    fn deinit(self: *TestSetup) void {
        const io = testing.io();
        if (!self.write_end_closed) self.write_end.close(io);
        self.read_end.close(io);
        self.doc_state.deinit();
        self.workspace.deinit();
        self.lsp_client.deinit();
        self.registry.deinit();
    }
};

fn expectErrorCode(alloc: std.mem.Allocator, ctx: *TestSetup, code: i64) !void {
    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(code, err.get("code").?.integer);
}

test "handleMessage initialize" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(protocol_version, result.get("protocolVersion").?.string);
    const info = result.get("serverInfo").?.object;
    try std.testing.expectEqualStrings("zig-mcp", info.get("name").?.string);
    try std.testing.expectEqualStrings(server_version, info.get("version").?.string);
    try std.testing.expectEqual(State.running, ctx.server.state);
}

test "handleMessage ping" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
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
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
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
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    try std.testing.expectEqual(State.running, ctx.server.state);
}

test "handleMessage unknown method returns method_not_found" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"nonexistent/method"}
    );
    try expectErrorCode(alloc, &ctx, -32601);
}

test "handleMessage invalid JSON returns parse_error" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle("not valid json{{{");
    try expectErrorCode(alloc, &ctx, -32700);
}

test "handleMessage non-object JSON returns invalid_request" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle("[1,2,3]");
    try expectErrorCode(alloc, &ctx, -32600);
}

test "handleMessage missing method returns invalid_request" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1}
    );
    try expectErrorCode(alloc, &ctx, -32600);
}

test "notification without id produces no response" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","method":"nonexistent/notification"}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    try std.testing.expectEqualStrings("", resp);
}

test "handleMessage tools/call unknown tool" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nonexistent"}}
    );
    try expectErrorCode(alloc, &ctx, -32601);
}

test "handleMessage tools/call invalid params" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"not_object"}
    );
    try expectErrorCode(alloc, &ctx, -32602);
}

test "handleMessage tools/call reports a failing tool as an MCP error result" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    const Failing = struct {
        fn handler(_: ToolContext, _: std.json.Value) ToolError![]const u8 {
            return error.FileNotFound;
        }
    };
    try ctx.registry.register(Failing.handler, .{
        .name = "boom",
        .description = "always fails",
        .inputSchema = .{},
    });

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"boom","arguments":{}}}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool);
    try std.testing.expectEqualStrings(
        "File not found",
        result.get("content").?.array.items[0].object.get("text").?.string,
    );
}

test "resources/list returns an empty JSON array, not an empty string" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"resources/list"}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const resources = parsed.value.object.get("result").?.object.get("resources").?;
    try std.testing.expect(resources == .array);
    try std.testing.expectEqual(@as(usize, 0), resources.array.items.len);
}

test "tools/list emits an object schema for every registered tool" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    const Noop = struct {
        fn handler(_: ToolContext, _: std.json.Value) ToolError![]const u8 {
            return "ok";
        }
    };
    // The registry takes ownership of the schema.
    const props: std.json.ObjectMap = .empty;
    try ctx.registry.register(Noop.handler, .{
        .name = "thing",
        .description = "does a thing",
        .inputSchema = .{ .properties = .{ .object = props }, .required = &.{"file"} },
    });

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    const schema = tools.items[0].object.get("inputSchema").?.object;
    try std.testing.expectEqualStrings("object", schema.get("type").?.string);
    // Never `null`: MCP clients drop tools whose properties are not an object.
    try std.testing.expect(schema.get("properties").? == .object);
    try std.testing.expectEqualStrings("file", schema.get("required").?.array.items[0].string);
}

test "string request ids are echoed back unchanged" {
    const alloc = std.testing.allocator;
    var ctx = try TestSetup.init(alloc);
    ctx.start();
    defer ctx.deinit();

    try ctx.handle(
        \\{"jsonrpc":"2.0","id":"abc-1","method":"ping"}
    );

    const resp = try ctx.getResponse();
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc-1", parsed.value.object.get("id").?.string);
}

test "handleMessage survives allocation failure at every step" {
    // Injected OOM must never leak: the arena is gone by the time the failure
    // propagates, so anything allocated from the test allocator has to be
    // released on the error path.
    const alloc = std.testing.allocator;
    const payloads = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"resources/list"}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"nope"}
        ,
        "not json",
    };

    for (payloads) |payload| {
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            var ctx = try TestSetup.init(alloc);
            ctx.start();
            defer ctx.deinit();

            var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = i });
            ctx.server.handleMessage(failing.allocator(), payload) catch {};
        }
    }
}
