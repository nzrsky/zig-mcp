const std = @import("std");
const McpTransport = @import("mcp/transport.zig").McpTransport;
const McpServer = @import("mcp/server.zig").McpServer;
const LspClient = @import("lsp/client.zig").LspClient;
const ZlsProcess = @import("zls/process.zig").ZlsProcess;
const findZls = @import("zls/process.zig").findZls;
const Registry = @import("bridge/registry.zig").Registry;
const tools = @import("bridge/tools.zig");
const DocumentState = @import("state/documents.zig").DocumentState;
const Workspace = @import("state/workspace.zig").Workspace;
const uri_util = @import("types/uri.zig");

// Pull in test references
comptime {
    _ = @import("types/json_rpc.zig");
    _ = @import("types/uri.zig");
    _ = @import("mcp/transport.zig");
    _ = @import("lsp/transport.zig");
    _ = @import("lsp/types.zig");
    _ = @import("mcp/types.zig");
    _ = @import("bridge/registry.zig");
    _ = @import("bridge/tools.zig");
    _ = @import("bridge/resources.zig");
    _ = @import("state/documents.zig");
    _ = @import("state/workspace.zig");
    _ = @import("zls/process.zig");
    _ = @import("lsp/client.zig");
    _ = @import("cmd/zig_runner.zig");
    _ = @import("cmd/zvm.zig");
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logToStderr,
};

fn logToStderr(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix = if (scope == .default)
        "[zig-mcp] "
    else
        "[zig-mcp/" ++ @tagName(scope) ++ "] ";
    std.debug.print(level_txt ++ " " ++ prefix ++ format ++ "\n", args);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var workspace_path: ?[]const u8 = null;
    var zls_path_arg: ?[]const u8 = null;
    var zig_path_arg: ?[]const u8 = null;
    var zvm_path_arg: ?[]const u8 = null;
    var allow_command_tools = false;

    // Skip program name
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "-w")) {
            workspace_path = args.next();
        } else if (std.mem.eql(u8, arg, "--zls-path")) {
            zls_path_arg = args.next();
        } else if (std.mem.eql(u8, arg, "--zig-path")) {
            zig_path_arg = args.next();
        } else if (std.mem.eql(u8, arg, "--zvm-path")) {
            zvm_path_arg = args.next();
        } else if (std.mem.eql(u8, arg, "--allow-command-tools")) {
            allow_command_tools = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("zig-mcp 0.1.0\n", .{});
            return;
        }
    }

    // Default workspace to cwd
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = workspace_path orelse (std.process.getCwd(&cwd_buf) catch {
        std.debug.print("Error: could not determine workspace path. Use --workspace <path>\n", .{});
        std.process.exit(1);
    });

    // Initialize workspace
    var workspace = Workspace.init(allocator, ws_path) catch {
        std.debug.print("Error: could not initialize workspace at '{s}'\n", .{ws_path});
        std.process.exit(1);
    };
    defer workspace.deinit();

    std.debug.print("[zig-mcp] Workspace: {s}\n", .{workspace.root_path});

    const zig_path = if (zig_path_arg) |p|
        try allocator.dupe(u8, p)
    else
        null;
    defer if (zig_path) |p| allocator.free(p);
    if (zig_path) |p| {
        if (!std.fs.path.isAbsolute(p)) {
            std.debug.print("[zig-mcp] Error: --zig-path must be an absolute path\n", .{});
            std.process.exit(1);
        }
    }

    const zvm_path = if (zvm_path_arg) |p|
        try allocator.dupe(u8, p)
    else
        null;
    defer if (zvm_path) |p| allocator.free(p);
    if (zvm_path) |p| {
        if (!std.fs.path.isAbsolute(p)) {
            std.debug.print("[zig-mcp] Error: --zvm-path must be an absolute path\n", .{});
            std.process.exit(1);
        }
    }

    if (allow_command_tools and zig_path == null) {
        std.debug.print("[zig-mcp] Error: --allow-command-tools requires --zig-path <absolute path>\n", .{});
        std.process.exit(1);
    }

    // Find ZLS
    const zls_path = if (zls_path_arg) |p| blk: {
        if (!std.fs.path.isAbsolute(p)) {
            std.debug.print("[zig-mcp] Error: --zls-path must be an absolute path\n", .{});
            std.process.exit(1);
        }
        break :blk try allocator.dupe(u8, p);
    }
    else
        findZls(allocator) catch {
            std.debug.print("[zig-mcp] Warning: ZLS not found. LSP-backed tools will not work.\n", .{});
            std.debug.print("[zig-mcp] Install ZLS or specify --zls-path <path>\n", .{});
            // Continue without ZLS — command tools still work
            return runWithoutZls(allocator, &workspace, allow_command_tools, zig_path, zvm_path, null);
        };
    defer allocator.free(zls_path);
    std.debug.print("[zig-mcp] ZLS: {s}\n", .{zls_path});

    // Spawn ZLS
    var zls_proc = ZlsProcess.init(allocator, workspace.root_path, zls_path);
    defer zls_proc.deinit();

    zls_proc.spawn() catch |err| {
        std.debug.print("[zig-mcp] Failed to spawn ZLS: {}\n", .{err});
        return runWithoutZls(allocator, &workspace, allow_command_tools, zig_path, zvm_path, null);
    };

    // Initialize LSP client
    var lsp_client = LspClient.init(allocator);
    defer lsp_client.deinit();

    const zls_stdin = zls_proc.getStdin() orelse {
        std.debug.print("[zig-mcp] Failed to get ZLS stdin pipe\n", .{});
        std.process.exit(1);
    };
    const zls_stdout = zls_proc.getStdout() orelse {
        std.debug.print("[zig-mcp] Failed to get ZLS stdout pipe\n", .{});
        std.process.exit(1);
    };

    const zls_stderr = zls_proc.getStderr();
    try lsp_client.connect(zls_stdin, zls_stdout, zls_stderr);

    // LspClient now owns the pipe handles — detach from ZlsProcess to avoid double-close
    zls_proc.detachPipes();

    // LSP initialize handshake
    std.debug.print("[zig-mcp] Initializing LSP session...\n", .{});
    const init_response = lsp_client.initialize(allocator, workspace.root_uri) catch |err| {
        std.debug.print("[zig-mcp] LSP initialize failed: {}\n", .{err});
        return runWithoutZls(allocator, &workspace, allow_command_tools, zig_path, zvm_path, zls_path);
    };
    allocator.free(init_response);
    std.debug.print("[zig-mcp] LSP session initialized\n", .{});

    // Initialize document state
    var doc_state = DocumentState.init(allocator, workspace.root_path);
    defer doc_state.deinit();

    // Initialize tool registry
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try tools.registerAll(&registry);

    // Initialize MCP transport
    var transport = McpTransport.init();

    // Run MCP server (with ZLS process for auto-reconnect on crash)
    var server = McpServer.init(allocator, &transport, &registry, &lsp_client, &doc_state, &workspace, allow_command_tools, zig_path, zvm_path, zls_path);
    server.zls_process = &zls_proc;
    std.debug.print("[zig-mcp] Server ready, waiting for MCP messages on stdin\n", .{});
    try server.run();

    std.debug.print("[zig-mcp] Server shutting down\n", .{});
}

/// Run in degraded mode without ZLS (command tools only).
fn runWithoutZls(
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    allow_command_tools: bool,
    zig_path: ?[]const u8,
    zvm_path: ?[]const u8,
    zls_path: ?[]const u8,
) !void {
    var doc_state = DocumentState.init(allocator, workspace.root_path);
    defer doc_state.deinit();

    var lsp_client = LspClient.init(allocator);
    defer lsp_client.deinit();

    var registry = Registry.init(allocator);
    defer registry.deinit();
    try tools.registerAll(&registry);

    var transport = McpTransport.init();
    var server = McpServer.init(allocator, &transport, &registry, &lsp_client, &doc_state, workspace, allow_command_tools, zig_path, zvm_path, zls_path);
    std.debug.print("[zig-mcp] Running without ZLS (command tools only)\n", .{});
    try server.run();
}

fn printUsage() void {
    std.debug.print(
        \\zig-mcp - MCP server for Zig (ZLS bridge)
        \\
        \\Usage: zig-mcp [options]
        \\
        \\Options:
        \\  --workspace, -w <path>   Workspace root directory (default: cwd)
        \\  --zls-path <path>        Path to ZLS binary (default: trusted fixed locations)
        \\  --zig-path <path>        Path to zig binary (required with --allow-command-tools)
        \\  --zvm-path <path>        Path to zvm binary (optional, enables zig_manage)
        \\  --allow-command-tools    Enable command execution tools (disabled by default)
        \\  --help, -h               Show this help message
        \\  --version                Show version
        \\
        \\The server communicates via newline-delimited JSON-RPC on stdin/stdout.
        \\Stderr is used for logging.
        \\
        \\Example MCP config (~/.claude/mcp_servers.json):
        \\  {{
        \\    "mcpServers": {{
        \\      "zig-mcp": {{
        \\        "command": "/path/to/zig-mcp",
        \\        "args": ["--workspace", "/path/to/project"]
        \\      }}
        \\    }}
        \\  }}
        \\
    , .{});
}
