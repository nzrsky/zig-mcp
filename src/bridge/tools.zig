const std = @import("std");
const registry = @import("registry.zig");
const mcp_types = @import("../mcp/types.zig");
const lsp_types = @import("../lsp/types.zig");
const uri_util = @import("../types/uri.zig");

const ToolContext = registry.ToolContext;
const ToolError = registry.ToolError;

/// Register all tools into the registry.
pub fn registerAll(reg: *registry.Registry) !void {
    try reg.register("zig_hover", handleHover, .{
        .name = "zig_hover",
        .description = "Get hover information (type info, documentation) for a symbol at a given position in a Zig file",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file (relative to workspace or absolute)" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
            .required = &.{ "file", "line", "character" },
        },
    });

    try reg.register("zig_definition", handleDefinition, .{
        .name = "zig_definition",
        .description = "Go to definition of a symbol at a given position in a Zig file",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
            .required = &.{ "file", "line", "character" },
        },
    });

    try reg.register("zig_references", handleReferences, .{
        .name = "zig_references",
        .description = "Find all references to a symbol at a given position",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
            .required = &.{ "file", "line", "character" },
        },
    });

    try reg.register("zig_completion", handleCompletion, .{
        .name = "zig_completion",
        .description = "Get completion suggestions at a given position in a Zig file",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
            .required = &.{ "file", "line", "character" },
        },
    });

    try reg.register("zig_diagnostics", handleDiagnostics, .{
        .name = "zig_diagnostics",
        .description = "Get diagnostics (errors, warnings) for a Zig file by opening it in ZLS",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
            }),
            .required = &.{"file"},
        },
    });

    try reg.register("zig_format", handleFormat, .{
        .name = "zig_format",
        .description = "Format a Zig source file using ZLS",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
            }),
            .required = &.{"file"},
        },
    });

    try reg.register("zig_rename", handleRename, .{
        .name = "zig_rename",
        .description = "Rename a symbol at a given position across the workspace",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
                .{ "new_name", "string", "New name for the symbol" },
            }),
            .required = &.{ "file", "line", "character", "new_name" },
        },
    });

    try reg.register("zig_document_symbols", handleDocumentSymbols, .{
        .name = "zig_document_symbols",
        .description = "List all symbols (functions, types, variables) defined in a Zig file",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
            }),
            .required = &.{"file"},
        },
    });

    try reg.register("zig_workspace_symbols", handleWorkspaceSymbols, .{
        .name = "zig_workspace_symbols",
        .description = "Search for symbols across the workspace",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "query", "string", "Search query for symbol names" },
            }),
            .required = &.{"query"},
        },
    });

    try reg.register("zig_code_action", handleCodeAction, .{
        .name = "zig_code_action",
        .description = "Get available code actions (quick fixes, refactors) for a range in a Zig file",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "start_line", "integer", "0-based start line" },
                .{ "start_char", "integer", "0-based start character" },
                .{ "end_line", "integer", "0-based end line" },
                .{ "end_char", "integer", "0-based end character" },
            }),
            .required = &.{ "file", "start_line", "start_char", "end_line", "end_char" },
        },
    });

    try reg.register("zig_signature_help", handleSignatureHelp, .{
        .name = "zig_signature_help",
        .description = "Get function signature help at a given position",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
            .required = &.{ "file", "line", "character" },
        },
    });

    try reg.register("zig_build", handleBuild, .{
        .name = "zig_build",
        .description = "Run `zig build` in the workspace. Returns build output (errors, warnings).",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "args", "string", "Additional arguments to pass to zig build (space-separated)" },
            }),
        },
    });

    try reg.register("zig_test", handleTest, .{
        .name = "zig_test",
        .description = "Run Zig tests. If file is specified, runs tests for that file. Otherwise runs `zig build test`.",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Optional: specific file to test" },
                .{ "filter", "string", "Optional: test name filter" },
            }),
        },
    });

    try reg.register("zig_check", handleCheck, .{
        .name = "zig_check",
        .description = "Run `zig ast-check` on a Zig source file to check for syntax errors",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file to check" },
            }),
            .required = &.{"file"},
        },
    });

    try reg.register("zig_version", handleVersion, .{
        .name = "zig_version",
        .description = "Get Zig and ZLS version information",
        .inputSchema = .{
            .properties = .{ .object = std.json.ObjectMap.init(reg.allocator) },
        },
    });

    try reg.register("zig_manage", handleManage, .{
        .name = "zig_manage",
        .description = "Manage Zig versions using zvm (Zig Version Manager)",
        .inputSchema = .{
            .properties = try makeProps(reg.allocator, &.{
                .{ "action", "string", "Action: 'list', 'install', or 'use'" },
                .{ "version", "string", "Version string (required for install/use)" },
            }),
            .required = &.{"action"},
        },
    });
}

// ── Helper: build JSON schema properties ──

fn makeProps(allocator: std.mem.Allocator, comptime fields: anytype) ToolError!std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    inline for (fields) |field| {
        var prop = std.json.ObjectMap.init(allocator);
        prop.put("type", .{ .string = field[1] }) catch return ToolError.OutOfMemory;
        prop.put("description", .{ .string = field[2] }) catch return ToolError.OutOfMemory;
        obj.put(field[0], .{ .object = prop }) catch return ToolError.OutOfMemory;
    }
    return .{ .object = obj };
}

// ── Helper: extract arguments ──

fn getStringArg(args: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (args) {
        .object => |obj| if (obj.get(key)) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null,
        else => null,
    };
}

fn getIntArg(args: std.json.Value, key: []const u8) ?i64 {
    return switch (args) {
        .object => |obj| if (obj.get(key)) |v| switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        } else null,
        else => null,
    };
}

// ── LSP-backed tool handlers ──

fn handleHover(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getIntArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getIntArg(args, "character") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const HoverParams = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/hover", HoverParams{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = line, .character = char },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    // Parse result from response
    return formatHoverResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleDefinition(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getIntArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getIntArg(args, "character") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/definition", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = line, .character = char },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatLocationResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleReferences(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getIntArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getIntArg(args, "character") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        context: struct { includeDeclaration: bool = true },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/references", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = line, .character = char },
        .context = .{},
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatLocationsResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleCompletion(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getIntArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getIntArg(args, "character") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/completion", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = line, .character = char },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatCompletionResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleDiagnostics(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;

    // Opening the file triggers ZLS to compute diagnostics
    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    // Give ZLS a moment to compute diagnostics, then request them via
    // a dummy hover (ZLS sends diagnostics as notifications, but we
    // can also just report "diagnostics sent, check your editor" or
    // use a pull-based approach if ZLS supports it)
    //
    // For now, return a message that the file has been opened and diagnostics
    // will appear via textDocument/publishDiagnostics notification
    return ctx.allocator.dupe(u8, "File opened in ZLS. Diagnostics are sent asynchronously by ZLS. Use zig_check for synchronous syntax checking.") catch return ToolError.OutOfMemory;
}

fn handleFormat(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        options: struct {
            tabSize: i64 = 4,
            insertSpaces: bool = true,
        },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/formatting", Params{
        .textDocument = .{ .uri = file_uri },
        .options = .{},
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatTextEditsResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleRename(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getIntArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getIntArg(args, "character") orelse return ToolError.InvalidParams;
    const new_name = getStringArg(args, "new_name") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        newName: []const u8,
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/rename", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = line, .character = char },
        .newName = new_name,
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatWorkspaceEditResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleDocumentSymbols(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/documentSymbol", Params{
        .textDocument = .{ .uri = file_uri },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatDocumentSymbolsResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleWorkspaceSymbols(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const query = getStringArg(args, "query") orelse return ToolError.InvalidParams;

    const Params = struct {
        query: []const u8,
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "workspace/symbol", Params{
        .query = query,
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatWorkspaceSymbolsResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleCodeAction(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const start_line = getIntArg(args, "start_line") orelse return ToolError.InvalidParams;
    const start_char = getIntArg(args, "start_char") orelse return ToolError.InvalidParams;
    const end_line = getIntArg(args, "end_line") orelse return ToolError.InvalidParams;
    const end_char = getIntArg(args, "end_char") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: struct {
            start: struct { line: i64, character: i64 },
            end: struct { line: i64, character: i64 },
        },
        context: struct {
            diagnostics: []const u8 = &.{},
        },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/codeAction", Params{
        .textDocument = .{ .uri = file_uri },
        .range = .{
            .start = .{ .line = start_line, .character = start_char },
            .end = .{ .line = end_line, .character = end_char },
        },
        .context = .{},
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatCodeActionsResponse(ctx.allocator, response) catch return ToolError.LspError;
}

fn handleSignatureHelp(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getIntArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getIntArg(args, "character") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return openPathToToolError(err);
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/signatureHelp", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = line, .character = char },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatSignatureHelpResponse(ctx.allocator, response) catch return ToolError.LspError;
}

// ── Command tool handlers ──

fn handleBuild(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    try requireCommandTools(ctx);
    const zig_path = commandBinary(ctx.zig_path) orelse return ToolError.CommandFailed;
    const extra_args = getStringArg(args, "args");
    return runZigCommand(ctx.allocator, zig_path, ctx.workspace.root_path, "build", extra_args) catch return ToolError.CommandFailed;
}

fn handleTest(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    try requireCommandTools(ctx);
    const zig_path = commandBinary(ctx.zig_path) orelse return ToolError.CommandFailed;
    const file = getStringArg(args, "file");
    const filter = getStringArg(args, "filter");

    if (file) |f| {
        const abs_path = uri_util.resolvePathWithinWorkspace(ctx.allocator, ctx.workspace.root_path, f) catch |err| return pathToToolError(err);
        defer ctx.allocator.free(abs_path);

        // zig test <file> [--test-filter <filter>]
        var cmd_args: std.ArrayList([]const u8) = .empty;
        defer cmd_args.deinit(ctx.allocator);
        cmd_args.append(ctx.allocator, "test") catch return ToolError.OutOfMemory;
        cmd_args.append(ctx.allocator, abs_path) catch return ToolError.OutOfMemory;
        if (filter) |filt| {
            cmd_args.append(ctx.allocator, "--test-filter") catch return ToolError.OutOfMemory;
            cmd_args.append(ctx.allocator, filt) catch return ToolError.OutOfMemory;
        }
        return runZigCommandArgs(ctx.allocator, zig_path, ctx.workspace.root_path, cmd_args.items) catch return ToolError.CommandFailed;
    } else {
        // zig build test
        return runZigCommand(ctx.allocator, zig_path, ctx.workspace.root_path, "build", "test") catch return ToolError.CommandFailed;
    }
}

fn handleCheck(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    try requireCommandTools(ctx);
    const zig_path = commandBinary(ctx.zig_path) orelse return ToolError.CommandFailed;
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const abs_path = uri_util.resolvePathWithinWorkspace(ctx.allocator, ctx.workspace.root_path, file) catch |err| return pathToToolError(err);
    defer ctx.allocator.free(abs_path);
    return runZigCommandArgs(ctx.allocator, zig_path, ctx.workspace.root_path, &.{ "ast-check", abs_path }) catch return ToolError.CommandFailed;
}

fn handleVersion(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    try requireCommandTools(ctx);
    _ = args;
    const zig_ver = if (ctx.zig_path) |zig_path|
        runZigCommand(ctx.allocator, zig_path, ctx.workspace.root_path, "version", null) catch "unknown"
    else
        "unknown";
    defer if (!std.mem.eql(u8, zig_ver, "unknown")) ctx.allocator.free(zig_ver);

    const zls_ver = if (ctx.zls_path) |zls_path|
        runCommand(ctx.allocator, &.{ zls_path, "--version" }, ctx.workspace.root_path) catch "unknown"
    else
        "unknown";
    defer if (!std.mem.eql(u8, zls_ver, "unknown")) ctx.allocator.free(zls_ver);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    aw.writer.print("Zig: {s}\nZLS: {s}", .{
        std.mem.trimRight(u8, zig_ver, "\n\r "),
        std.mem.trimRight(u8, zls_ver, "\n\r "),
    }) catch return ToolError.OutOfMemory;
    return aw.toOwnedSlice() catch return ToolError.OutOfMemory;
}

fn handleManage(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    try requireCommandTools(ctx);
    const zvm_path = commandBinary(ctx.zvm_path) orelse {
        return ctx.allocator.dupe(u8, "zvm path not configured. Start server with --zvm-path <absolute path>") catch return ToolError.OutOfMemory;
    };
    const action = getStringArg(args, "action") orelse return ToolError.InvalidParams;
    const version = getStringArg(args, "version");

    if (std.mem.eql(u8, action, "list")) {
        return runCommand(ctx.allocator, &.{ zvm_path, "list" }, ctx.workspace.root_path) catch
            return ctx.allocator.dupe(u8, "zvm not found. Install from https://github.com/tristanisham/zvm") catch return ToolError.OutOfMemory;
    } else if (std.mem.eql(u8, action, "install")) {
        const ver = version orelse return ToolError.InvalidParams;
        return runCommand(ctx.allocator, &.{ zvm_path, "install", ver }, ctx.workspace.root_path) catch return ToolError.CommandFailed;
    } else if (std.mem.eql(u8, action, "use")) {
        const ver = version orelse return ToolError.InvalidParams;
        return runCommand(ctx.allocator, &.{ zvm_path, "use", ver }, ctx.workspace.root_path) catch return ToolError.CommandFailed;
    }
    return ToolError.InvalidParams;
}

// ── Response formatters ──

fn formatHoverResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response from ZLS"),
    };

    // Check for result field
    const result = obj.get("result") orelse return allocator.dupe(u8, "No result in response");
    if (result == .null) return allocator.dupe(u8, "No hover information available");

    const result_obj = switch (result) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid hover result"),
    };

    // Extract contents
    const contents = result_obj.get("contents") orelse return allocator.dupe(u8, "No contents in hover");
    return switch (contents) {
        .string => |s| allocator.dupe(u8, s),
        .object => |o| {
            if (o.get("value")) |v| {
                return switch (v) {
                    .string => |s| allocator.dupe(u8, s),
                    else => allocator.dupe(u8, "Hover content available"),
                };
            }
            return allocator.dupe(u8, "Hover content available");
        },
        else => allocator.dupe(u8, "Hover content available"),
    };
}

fn formatLocationResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No result");
    if (result == .null) return allocator.dupe(u8, "No definition found");

    // Result can be a Location or Location[]
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    switch (result) {
        .object => {
            try formatSingleLocation(&aw.writer, result);
        },
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                if (i > 0) try aw.writer.writeByte('\n');
                try formatSingleLocation(&aw.writer, item);
            }
            if (arr.items.len == 0) {
                try aw.writer.writeAll("No definition found");
            }
        },
        else => try aw.writer.writeAll("No definition found"),
    }
    return try aw.toOwnedSlice();
}

fn formatSingleLocation(w: *std.Io.Writer, loc: std.json.Value) !void {
    const loc_obj = switch (loc) {
        .object => |o| o,
        else => return,
    };
    const uri_val = loc_obj.get("uri") orelse return;
    const uri_str = switch (uri_val) {
        .string => |s| s,
        else => return,
    };
    // Strip file:// prefix for readability
    const path = if (std.mem.startsWith(u8, uri_str, "file://"))
        uri_str[7..]
    else
        uri_str;

    if (loc_obj.get("range")) |range| {
        if (range == .object) {
            if (range.object.get("start")) |start| {
                if (start == .object) {
                    const line = switch (start.object.get("line") orelse .null) {
                        .integer => |i| i,
                        else => 0,
                    };
                    const char = switch (start.object.get("character") orelse .null) {
                        .integer => |i| i,
                        else => 0,
                    };
                    try w.print("{s}:{d}:{d}", .{ path, line + 1, char + 1 });
                    return;
                }
            }
        }
    }
    try w.print("{s}", .{path});
}

fn formatLocationsResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    // Same as location but expects an array
    return formatLocationResponse(allocator, response);
}

fn formatCompletionResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No completions");
    if (result == .null) return allocator.dupe(u8, "No completions available");

    // Can be CompletionList or CompletionItem[]
    const items = switch (result) {
        .object => |o| switch (o.get("items") orelse .null) {
            .array => |a| a,
            else => return allocator.dupe(u8, "No completion items"),
        },
        .array => |a| a,
        else => return allocator.dupe(u8, "No completions"),
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const max_items: usize = 50; // Limit output
    for (items.items, 0..) |item, i| {
        if (i >= max_items) {
            try aw.writer.print("\n... and {d} more items", .{items.items.len - max_items});
            break;
        }
        if (i > 0) try aw.writer.writeByte('\n');
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = switch (item_obj.get("label") orelse .null) {
            .string => |s| s,
            else => "?",
        };
        const kind: i64 = switch (item_obj.get("kind") orelse .null) {
            .integer => |k| k,
            else => 0,
        };
        const kind_name = lsp_types.completionKindName(if (kind >= 0) @intCast(kind) else null);
        try aw.writer.print("{s} ({s})", .{ label, kind_name });
        if (item_obj.get("detail")) |detail| {
            if (detail == .string) {
                try aw.writer.print(" - {s}", .{detail.string});
            }
        }
    }
    if (items.items.len == 0) {
        try aw.writer.writeAll("No completions available");
    }
    return try aw.toOwnedSlice();
}

fn formatTextEditsResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No edits");
    if (result == .null) return allocator.dupe(u8, "No formatting changes needed");

    const edits = switch (result) {
        .array => |a| a,
        else => return allocator.dupe(u8, "No edits"),
    };

    if (edits.items.len == 0) return allocator.dupe(u8, "No formatting changes needed");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("{d} formatting edit(s) available:\n", .{edits.items.len});
    for (edits.items, 0..) |edit, i| {
        if (i >= 10) {
            try aw.writer.print("... and {d} more edits", .{edits.items.len - 10});
            break;
        }
        const edit_obj = switch (edit) {
            .object => |o| o,
            else => continue,
        };
        if (edit_obj.get("newText")) |new_text| {
            if (new_text == .string) {
                const text = new_text.string;
                const preview = if (text.len > 80) text[0..80] else text;
                try aw.writer.print("  Edit {d}: \"{s}\"\n", .{ i + 1, preview });
            }
        }
    }
    return try aw.toOwnedSlice();
}

fn formatWorkspaceEditResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No rename result");
    if (result == .null) return allocator.dupe(u8, "Rename not available at this position");

    const result_obj = switch (result) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid rename result"),
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    if (result_obj.get("changes")) |changes| {
        if (changes == .object) {
            try aw.writer.print("Rename affects {d} file(s):\n", .{changes.object.count()});
            var it = changes.object.iterator();
            while (it.next()) |entry| {
                const path = if (std.mem.startsWith(u8, entry.key_ptr.*, "file://"))
                    entry.key_ptr.*[7..]
                else
                    entry.key_ptr.*;
                const edit_count: usize = switch (entry.value_ptr.*) {
                    .array => |a| a.items.len,
                    else => 0,
                };
                try aw.writer.print("  {s}: {d} edit(s)\n", .{ path, edit_count });
            }
            return try aw.toOwnedSlice();
        }
    }
    try aw.writer.writeAll("Rename result received");
    return try aw.toOwnedSlice();
}

fn formatDocumentSymbolsResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No symbols");
    if (result == .null) return allocator.dupe(u8, "No symbols found");

    const symbols = switch (result) {
        .array => |a| a,
        else => return allocator.dupe(u8, "No symbols"),
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    for (symbols.items) |sym| {
        try formatSymbol(&aw.writer, sym, 0);
    }
    if (symbols.items.len == 0) {
        try aw.writer.writeAll("No symbols found");
    }
    return try aw.toOwnedSlice();
}

fn formatSymbol(w: *std.Io.Writer, sym: std.json.Value, depth: usize) !void {
    const sym_obj = switch (sym) {
        .object => |o| o,
        else => return,
    };

    // Indent
    for (0..depth) |_| try w.writeAll("  ");

    const name = switch (sym_obj.get("name") orelse .null) {
        .string => |s| s,
        else => "?",
    };
    const kind: u32 = switch (sym_obj.get("kind") orelse .null) {
        .integer => |k| if (k >= 0) @intCast(k) else 0,
        else => 0,
    };

    try w.print("{s} ({s})", .{ name, lsp_types.symbolKindName(kind) });

    // Line info
    if (sym_obj.get("range") orelse sym_obj.get("selectionRange")) |range| {
        if (range == .object) {
            if (range.object.get("start")) |start| {
                if (start == .object) {
                    const line: i64 = switch (start.object.get("line") orelse .null) {
                        .integer => |i| i,
                        else => 0,
                    };
                    try w.print(" L{d}", .{line + 1});
                }
            }
        }
    }

    try w.writeByte('\n');

    // Recurse into children
    if (sym_obj.get("children")) |children| {
        if (children == .array) {
            for (children.array.items) |child| {
                try formatSymbol(w, child, depth + 1);
            }
        }
    }
}

fn formatWorkspaceSymbolsResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    // Same format as document symbols but with location info
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No symbols");
    if (result == .null) return allocator.dupe(u8, "No symbols found");

    const symbols = switch (result) {
        .array => |a| a,
        else => return allocator.dupe(u8, "No symbols"),
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    for (symbols.items) |sym| {
        const sym_obj = switch (sym) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (sym_obj.get("name") orelse .null) {
            .string => |s| s,
            else => "?",
        };
        const kind: u32 = switch (sym_obj.get("kind") orelse .null) {
            .integer => |k| if (k >= 0) @intCast(k) else 0,
            else => 0,
        };
        try aw.writer.print("{s} ({s})", .{ name, lsp_types.symbolKindName(kind) });

        if (sym_obj.get("location")) |loc| {
            if (loc == .object) {
                if (loc.object.get("uri")) |loc_uri| {
                    if (loc_uri == .string) {
                        const path = if (std.mem.startsWith(u8, loc_uri.string, "file://"))
                            loc_uri.string[7..]
                        else
                            loc_uri.string;
                        try aw.writer.print(" in {s}", .{path});
                    }
                }
            }
        }
        try aw.writer.writeByte('\n');
    }
    if (symbols.items.len == 0) {
        try aw.writer.writeAll("No symbols found");
    }
    return try aw.toOwnedSlice();
}

fn formatCodeActionsResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No code actions");
    if (result == .null) return allocator.dupe(u8, "No code actions available");

    const actions = switch (result) {
        .array => |a| a,
        else => return allocator.dupe(u8, "No code actions"),
    };

    if (actions.items.len == 0) return allocator.dupe(u8, "No code actions available");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    for (actions.items, 0..) |action, i| {
        const action_obj = switch (action) {
            .object => |o| o,
            else => continue,
        };
        const title = switch (action_obj.get("title") orelse .null) {
            .string => |s| s,
            else => "Unknown action",
        };
        const kind = switch (action_obj.get("kind") orelse .null) {
            .string => |s| s,
            else => "",
        };
        try aw.writer.print("{d}. {s}", .{ i + 1, title });
        if (kind.len > 0) {
            try aw.writer.print(" [{s}]", .{kind});
        }
        try aw.writer.writeByte('\n');
    }
    return try aw.toOwnedSlice();
}

fn formatSignatureHelpResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid response"),
    };

    const result = obj.get("result") orelse return allocator.dupe(u8, "No signature help");
    if (result == .null) return allocator.dupe(u8, "No signature help available");

    const result_obj = switch (result) {
        .object => |o| o,
        else => return allocator.dupe(u8, "Invalid signature help"),
    };

    const sigs = switch (result_obj.get("signatures") orelse .null) {
        .array => |a| a,
        else => return allocator.dupe(u8, "No signatures"),
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    for (sigs.items) |sig| {
        const sig_obj = switch (sig) {
            .object => |o| o,
            else => continue,
        };
        const label = switch (sig_obj.get("label") orelse .null) {
            .string => |s| s,
            else => "?",
        };
        try aw.writer.print("{s}\n", .{label});
    }
    if (sigs.items.len == 0) {
        try aw.writer.writeAll("No signature help available");
    }
    return try aw.toOwnedSlice();
}

// ── Command execution helpers ──

fn runZigCommand(allocator: std.mem.Allocator, zig_path: []const u8, cwd: []const u8, subcmd: []const u8, extra: ?[]const u8) ![]const u8 {
    if (extra) |args_str| {
        // Split extra args by space
        var arg_list: std.ArrayList([]const u8) = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, zig_path);
        try arg_list.append(allocator, subcmd);
        var it = std.mem.splitScalar(u8, args_str, ' ');
        while (it.next()) |arg| {
            if (arg.len > 0) try arg_list.append(allocator, arg);
        }
        return runCommandSlice(allocator, arg_list.items, cwd);
    }
    return runCommandSlice(allocator, &.{ zig_path, subcmd }, cwd);
}

fn runZigCommandArgs(allocator: std.mem.Allocator, zig_path: []const u8, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(allocator);
    try arg_list.append(allocator, zig_path);
    for (args) |arg| {
        try arg_list.append(allocator, arg);
    }
    return runCommandSlice(allocator, arg_list.items, cwd);
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) ![]const u8 {
    return runCommandSlice(allocator, argv, cwd);
}

fn runCommandSlice(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
        return result.stdout;
    }

    // On failure, combine stdout + stderr
    defer allocator.free(result.stdout);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    if (result.stdout.len > 0) {
        try aw.writer.writeAll(result.stdout);
    }
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0) try aw.writer.writeByte('\n');
        try aw.writer.writeAll(result.stderr);
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        const exit_code: u8 = switch (result.term) {
            .Exited => |c| c,
            else => 1,
        };
        try aw.writer.print("Command exited with code {d}", .{exit_code});
    }
    return try aw.toOwnedSlice();
}

fn lspToToolError(err: anytype) ToolError {
    return switch (err) {
        error.NotConnected => ToolError.NotConnected,
        error.RequestTimeout => ToolError.RequestTimeout,
        error.NoResponse => ToolError.NoResponse,
        else => ToolError.LspError,
    };
}

fn openPathToToolError(err: anytype) ToolError {
    return switch (err) {
        error.PathOutsideWorkspace => ToolError.PathOutsideWorkspace,
        error.FileNotFound => ToolError.FileNotFound,
        error.FileReadError => ToolError.FileReadError,
        else => ToolError.LspError,
    };
}

fn pathToToolError(err: anytype) ToolError {
    return switch (err) {
        error.PathOutsideWorkspace => ToolError.PathOutsideWorkspace,
        error.FileNotFound => ToolError.FileNotFound,
        error.OutOfMemory => ToolError.OutOfMemory,
        else => ToolError.CommandFailed,
    };
}

fn requireCommandTools(ctx: ToolContext) ToolError!void {
    if (!ctx.allow_command_tools) return ToolError.CommandToolsDisabled;
}

fn commandBinary(path: ?[]const u8) ?[]const u8 {
    return path;
}

// ── Tests ──

test "getStringArg extracts string from JSON object" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"file\":\"main.zig\",\"count\":42}", .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("main.zig", getStringArg(parsed.value, "file").?);
    try std.testing.expect(getStringArg(parsed.value, "count") == null); // int, not string
    try std.testing.expect(getStringArg(parsed.value, "missing") == null);
}

test "getStringArg from non-object returns null" {
    try std.testing.expect(getStringArg(.null, "key") == null);
    try std.testing.expect(getStringArg(.{ .integer = 42 }, "key") == null);
}

test "getIntArg extracts integer from JSON object" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"line\":10,\"name\":\"foo\"}", .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 10), getIntArg(parsed.value, "line").?);
    try std.testing.expect(getIntArg(parsed.value, "name") == null); // string, not int
    try std.testing.expect(getIntArg(parsed.value, "missing") == null);
}

test "getIntArg from float rounds" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"val\":3.0}", .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 3), getIntArg(parsed.value, "val").?);
}

test "getIntArg from non-object returns null" {
    try std.testing.expect(getIntArg(.null, "key") == null);
}

test "requireCommandTools enforces policy" {
    const alloc = std.testing.allocator;
    const ctx = ToolContext{
        .lsp_client = undefined,
        .doc_state = undefined,
        .workspace = undefined,
        .allocator = alloc,
        .allow_command_tools = false,
        .zig_path = null,
        .zvm_path = null,
        .zls_path = null,
    };
    try std.testing.expectError(ToolError.CommandToolsDisabled, requireCommandTools(ctx));
}

test "commandBinary returns null when unset" {
    try std.testing.expect(commandBinary(null) == null);
    try std.testing.expectEqualStrings("/usr/bin/zig", commandBinary("/usr/bin/zig").?);
}

test "formatHoverResponse with markup content" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"contents":{"kind":"markdown","value":"fn main() void"}}}
    ;
    const result = try formatHoverResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("fn main() void", result);
}

test "formatHoverResponse null result" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":null}
    ;
    const result = try formatHoverResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("No hover information available", result);
}

test "formatHoverResponse string content" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"contents":"plain text hover"}}
    ;
    const result = try formatHoverResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("plain text hover", result);
}

test "formatLocationResponse single location" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"uri":"file:///src/main.zig","range":{"start":{"line":9,"character":4},"end":{"line":9,"character":10}}}}
    ;
    const result = try formatLocationResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("/src/main.zig:10:5", result);
}

test "formatLocationResponse null result" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":null}
    ;
    const result = try formatLocationResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("No definition found", result);
}

test "formatLocationResponse array of locations" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"uri":"file:///a.zig","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}},{"uri":"file:///b.zig","range":{"start":{"line":4,"character":2},"end":{"line":4,"character":8}}}]}
    ;
    const result = try formatLocationResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "/a.zig:1:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/b.zig:5:3") != null);
}

test "formatCompletionResponse with items" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"isIncomplete":false,"items":[{"label":"println","kind":3,"detail":"fn println(...)"},{"label":"print","kind":3}]}}
    ;
    const result = try formatCompletionResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "println (Function)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "print (Function)") != null);
}

test "formatCompletionResponse null result" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":null}
    ;
    const result = try formatCompletionResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("No completions available", result);
}

test "formatDocumentSymbolsResponse" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"name":"main","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":5,"character":0}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":4}}}]}
    ;
    const result = try formatDocumentSymbolsResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "main (Function)") != null);
}

test "formatDocumentSymbolsResponse with nested children" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"name":"Foo","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"children":[{"name":"bar","kind":12,"range":{"start":{"line":1,"character":0},"end":{"line":3,"character":0}},"selectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}}]}]}
    ;
    const result = try formatDocumentSymbolsResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Foo (Struct)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "  bar (Function)") != null);
}

test "formatCodeActionsResponse empty" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[]}
    ;
    const result = try formatCodeActionsResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("No code actions available", result);
}

test "formatSignatureHelpResponse null result" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":null}
    ;
    const result = try formatSignatureHelpResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("No signature help available", result);
}

test "formatTextEditsResponse no changes" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":null}
    ;
    const result = try formatTextEditsResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("No formatting changes needed", result);
}

test "formatWorkspaceEditResponse with changes" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"changes":{"file:///src/main.zig":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"new_name"}]}}}
    ;
    const result = try formatWorkspaceEditResponse(alloc, response);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "1 file(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/src/main.zig") != null);
}

test "makeProps builds valid JSON schema properties" {
    const alloc = std.testing.allocator;
    const props = try makeProps(alloc, &.{
        .{ "file", "string", "Path to file" },
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
    try std.testing.expectEqualStrings("string", props.object.get("file").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("integer", props.object.get("line").?.object.get("type").?.string);
}
