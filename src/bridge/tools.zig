const std = @import("std");
const registry = @import("registry.zig");
const mcp_types = @import("../mcp/types.zig");
const lsp_types = @import("../lsp/types.zig");
const uri_util = @import("../types/uri.zig");
const ast_tools = @import("ast_tools.zig");

const ToolContext = registry.ToolContext;
const ToolError = registry.ToolError;

/// Register all tools into the registry.
pub fn registerAll(reg: *registry.Registry) !void {
    // Descriptions say what the tool knows that the alternatives do not.
    // A caller with a shell and a grep will not reach for a tool whose
    // description only restates its name.

    try reg.register(handleDefinition, .{
        .name = "zig_definition",
        .description = "Jump to where a Zig symbol is declared. Pass `symbol` for a name lookup, or `file`+`line`+`character` for a cursor position. Resolved by the compiler's semantic model, so it follows imports, aliases and `@import` chains and lands on the one true declaration — unlike a text search, which returns every mention of the name.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "symbol", "string", "Symbol name, e.g. \"PosixMutex\" or \"LspClient.sendRequest\". Use this when you know the name but not the position." },
                .{ "file", "string", "Path to the Zig source file (only with line and character)" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
        },
    });

    try reg.register(handleReferences, .{
        .name = "zig_references",
        .description = "Find every use of a Zig symbol across the workspace. Pass `symbol` for a name lookup, or `file`+`line`+`character`. Finds usages reached through imports and aliases, and skips same-named identifiers in other scopes, comments and strings — which is exactly where grep gives both false hits and misses.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "symbol", "string", "Symbol name to find usages of" },
                .{ "file", "string", "Path to the Zig source file (only with line and character)" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
        },
    });

    try reg.register(handleHover, .{
        .name = "zig_hover",
        .description = "Resolved type and doc comment for a Zig symbol. Pass `symbol` or `file`+`line`+`character`. Shows the type after comptime evaluation and inference — what the compiler concluded, which is not visible in the source text (`var x = foo()` tells you nothing on its own).",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "symbol", "string", "Symbol name to inspect" },
                .{ "file", "string", "Path to the Zig source file (only with line and character)" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
        },
    });

    try reg.register(handleDiagnostics, .{
        .name = "zig_diagnostics",
        .description = "Errors and warnings for one Zig file, straight from ZLS. Re-syncs the file first, so results match what is on disk right now. Answers for a single file without building the project — faster than `zig build` when you only touched one file, and it works even when an unrelated part of the tree does not compile.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
            }),
            .required = &.{"file"},
        },
    });

    try reg.register(handleWorkspaceSymbols, .{
        .name = "zig_workspace_symbols",
        .description = "Search declarations across the workspace by name. Returns declarations only, with their kind (function, struct, constant...) — a name search over the symbol index rather than over the file text, so call sites and comments do not drown the result.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "query", "string", "Search query for symbol names" },
            }),
            .required = &.{"query"},
        },
    });

    try reg.register(handleDocumentSymbols, .{
        .name = "zig_document_symbols",
        .description = "Outline of one Zig file: every declaration with its kind, nesting and line number. Cheaper than reading the file when you only need its shape.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
            }),
            .required = &.{"file"},
        },
    });

    try reg.register(handleCompletion, .{
        .name = "zig_completion",
        .description = "What can legally follow at a given position: fields, methods and declarations in scope, with their types. Use it to discover an API instead of guessing at member names.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
            .required = &.{ "file", "line", "character" },
        },
    });

    try reg.register(handleSignatureHelp, .{
        .name = "zig_signature_help",
        .description = "Parameter list and types of the function being called at a position — the real signature, including comptime and generic parameters.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
            .required = &.{ "file", "line", "character" },
        },
    });

    try reg.register(handleRename, .{
        .name = "zig_rename",
        .description = "Preview a workspace-wide rename of a symbol: which files change and how many edits each takes. Scope-aware, so it will not touch a same-named identifier elsewhere the way a search-and-replace would.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
                .{ "new_name", "string", "New name for the symbol" },
            }),
            .required = &.{ "file", "line", "character", "new_name" },
        },
    });

    try reg.register(handleCodeAction, .{
        .name = "zig_code_action",
        .description = "Quick fixes and refactors ZLS offers for a range — discard-unused, add missing discard, organize imports and the like.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
                .{ "start_line", "integer", "0-based start line" },
                .{ "start_char", "integer", "0-based start character" },
                .{ "end_line", "integer", "0-based end line" },
                .{ "end_char", "integer", "0-based end character" },
            }),
            .required = &.{ "file", "start_line", "start_char", "end_line", "end_char" },
        },
    });

    try reg.register(handleInlayHints, .{
        .name = "zig_inlay_hints",
        .description = "Every type the compiler inferred in a file, in one call: `var x = foo()` gets its resolved type, call arguments get their parameter names. None of this exists in the source text, so no amount of reading or searching recovers it.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Path to the Zig source file" },
            }),
            .required = &.{"file"},
        },
    });

    try reg.register(handleTypeDefinition, .{
        .name = "zig_type_definition",
        .description = "Jump to the declaration of a value's *type*, not of the value. On `const client = LspClient.init(...)` this lands on `LspClient`, where `zig_definition` would land on `client`.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "symbol", "string", "Symbol name whose type to resolve" },
                .{ "file", "string", "Path to the Zig source file (only with line and character)" },
                .{ "line", "integer", "0-based line number" },
                .{ "character", "integer", "0-based character offset" },
            }),
        },
    });

    try reg.register(handleAstQuery, .{
        .name = "zig_ast_query",
        .description = "Find code by shape rather than by text: empty `catch {}` blocks, `catch unreachable`, `undefined` initializers, `unreachable`, `@panic`. Matches over the syntax tree, so occurrences inside comments and string literals are never reported and a form spread across several lines is found exactly like a one-liner — both of which a regular expression gets wrong.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "shape", "string", "One of: empty_catch, catch_unreachable, undefined_init, unreachable_literal, panic" },
                .{ "file", "string", "Optional: one file. Omit to scan the whole workspace." },
            }),
            .required = &.{"shape"},
        },
    });

    try reg.register(handleUnusedPrivate, .{
        .name = "zig_unused_private",
        .description = "Private declarations nothing refers to. A declaration without `pub` cannot be named from another file, so the file is the whole search space and the answer is exact. Neither the compiler nor zlint's unused-decls reports these.",
        .inputSchema = .{
            .properties = try mcp_types.makeProperty(reg.allocator, &.{
                .{ "file", "string", "Optional: one file. Omit to scan the whole workspace." },
            }),
        },
    });

    // Deliberately not registered: zig_build, zig_test, zig_format,
    // zig_version, zig_check and zig_manage. They wrapped `zig build`,
    // `zig test`, `zig fmt`, `zig version`, `zig ast-check` and `zvm`, and a
    // wrapper loses to the shell it wraps — no pipes, no redirection, no
    // working directory of its own. Session transcripts bear this out: 526
    // `zig build` invocations through the shell against zero calls to the
    // tool. What is left here is what a shell cannot do.
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
            // `@intFromFloat` is illegal behaviour outside the target range, so
            // a client sending `{"line": 1e300}` (or a NaN) must not reach it.
            .float => |f| floatToInt(f),
            else => null,
        } else null,
        else => null,
    };
}

fn floatToInt(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    const limit: f64 = 9223372036854775808.0; // 2^63
    if (f >= limit or f < -limit) return null;
    return @intFromFloat(f);
}

/// A 0-based line/character argument. Negative positions are meaningless in
/// LSP and would be sent on the wire as-is.
fn getPositionArg(args: std.json.Value, key: []const u8) ?i64 {
    const value = getIntArg(args, key) orelse return null;
    return if (value < 0) null else value;
}

/// Longest prefix of `text` that fits in `max` bytes without splitting a UTF-8
/// sequence — a split one would make the JSON response invalid.
fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

// ── Symbol resolution ──
//
// Every position-based LSP request needs a line and a character offset. A
// caller that is reasoning about code has a *name*, not a cursor, and getting
// coordinates means reading the file first — which is the work the tool was
// supposed to save. So each of these tools also accepts `symbol` and resolves
// the position itself through `workspace/symbol`.

/// A symbol location resolved out of a `workspace/symbol` reply.
const ResolvedSymbol = struct {
    /// Document URI, allocated with the context allocator.
    uri: []const u8,
    line: i64,
    character: i64,
    name: []const u8,
    kind: u32,
    /// Lines the declaration spans. A re-export (`const X = @import(..).X;`)
    /// is one line; the declaration it points at is not. Ranking by this
    /// keeps a symbol query from landing on an alias.
    span: i64 = 0,
};

/// Directories that never hold source worth searching.
fn isSkippedDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, ".coverage");
}

/// Upper bounds so a huge tree cannot turn one tool call into a full scan.
const max_scanned_files: usize = 4096;
const max_candidate_files: usize = 32;

/// Find where `query` is declared.
///
/// ZLS advertises `workspaceSymbolProvider` but answers `[]` for every query,
/// so the index cannot be used. Instead: shortlist files whose text contains
/// the name (cheap, no LSP traffic), then ask ZLS for each candidate's
/// document symbols and match exactly. The shortlist is textual, but the match
/// is semantic — a mention in a comment or a call site never wins, because
/// only declarations appear in a document symbol tree.
fn resolveSymbol(ctx: ToolContext, query: []const u8) ToolError!ResolvedSymbol {
    const all = try resolveSymbolAll(ctx, query);
    return all[0];
}

/// Every declaration of `query`, widest first.
///
/// More than one is normal in Zig: `const X = @import("x.zig").X;` is its own
/// declaration, and ZLS reports references against whichever one is under the
/// cursor. Callers that want the whole picture ask at each of them.
fn resolveSymbolAll(ctx: ToolContext, query: []const u8) ToolError![]ResolvedSymbol {
    if (query.len == 0) return ToolError.InvalidParams;

    var dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.workspace.root_path, .{ .iterate = true }) catch
        return ToolError.FileReadError;
    defer dir.close(ctx.io);

    var walker = dir.walk(ctx.allocator) catch return ToolError.OutOfMemory;
    defer walker.deinit();

    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(ctx.allocator);

    var scanned: usize = 0;
    while (walker.next(ctx.io) catch null) |entry| {
        if (scanned >= max_scanned_files or candidates.items.len >= max_candidate_files) break;
        if (entry.kind == .directory) {
            if (isSkippedDir(entry.basename)) walker.leave(ctx.io);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        scanned += 1;

        const contents = dir.readFileAlloc(ctx.io, entry.path, ctx.allocator, std.Io.Limit.limited(max_source_bytes)) catch continue;
        defer ctx.allocator.free(contents);
        if (std.mem.indexOf(u8, contents, query) == null) continue;

        const owned = ctx.allocator.dupe(u8, entry.path) catch return ToolError.OutOfMemory;
        candidates.append(ctx.allocator, owned) catch return ToolError.OutOfMemory;
    }

    var matches: std.ArrayList(ResolvedSymbol) = .empty;
    errdefer matches.deinit(ctx.allocator);

    for (candidates.items) |rel_path| {
        const uri = ctx.doc_state.ensureOpen(ctx.lsp_client, rel_path, ctx.allocator) catch continue;
        defer ctx.allocator.free(uri);

        const Params = struct { textDocument: struct { uri: []const u8 } };
        const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/documentSymbol", Params{
            .textDocument = .{ .uri = uri },
        }) catch |err| return lspToToolError(err);
        defer ctx.allocator.free(response);

        const found = (try findSymbolInResponse(ctx, response, uri, query)) orelse continue;
        matches.append(ctx.allocator, found) catch return ToolError.OutOfMemory;
        // No early exit: every candidate is opened on purpose. ZLS computes
        // references only across documents it holds, so stopping at the first
        // match would make `zig_references` silently miss the other files.
    }

    if (matches.items.len == 0) return ToolError.SymbolNotFound;
    std.mem.sort(ResolvedSymbol, matches.items, {}, struct {
        fn widestFirst(_: void, a: ResolvedSymbol, b: ResolvedSymbol) bool {
            return a.span > b.span;
        }
    }.widestFirst);
    return matches.toOwnedSlice(ctx.allocator) catch ToolError.OutOfMemory;
}

const max_source_bytes: usize = 4 * 1024 * 1024;

fn findSymbolInResponse(
    ctx: ToolContext,
    response: []const u8,
    uri: []const u8,
    query: []const u8,
) ToolError!?ResolvedSymbol {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, response, .{}) catch
        return ToolError.LspError;
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .object => |o| switch (o.get("result") orelse .null) {
            .array => |a| a,
            else => return null,
        },
        else => return null,
    };
    return searchSymbolTree(ctx, items, uri, query);
}

/// Depth-first search for an exact name match, nested declarations included.
fn searchSymbolTree(
    ctx: ToolContext,
    items: std.json.Array,
    uri: []const u8,
    query: []const u8,
) ToolError!?ResolvedSymbol {
    var best: ?ResolvedSymbol = null;
    for (items.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse .null) {
            .string => |n| n,
            else => "",
        };

        if (std.mem.eql(u8, name, query)) {
            const full = obj.get("range") orelse .null;
            // `selectionRange` covers the identifier itself; `range` covers the
            // whole declaration and would point at `pub`, where ZLS has nothing
            // to say.
            const range = obj.get("selectionRange") orelse obj.get("range") orelse .null;
            const start = switch (range) {
                .object => |r| switch (r.get("start") orelse .null) {
                    .object => |st| st,
                    else => continue,
                },
                else => continue,
            };
            const found = ResolvedSymbol{
                .uri = ctx.allocator.dupe(u8, uri) catch return ToolError.OutOfMemory,
                .line = switch (start.get("line") orelse .null) {
                    .integer => |i| i,
                    else => 0,
                },
                .character = switch (start.get("character") orelse .null) {
                    .integer => |i| i,
                    else => 0,
                },
                .name = ctx.allocator.dupe(u8, name) catch return ToolError.OutOfMemory,
                .kind = switch (obj.get("kind") orelse .null) {
                    .integer => |k| if (k >= 0) @intCast(k) else 0,
                    else => 0,
                },
                .span = rangeSpan(full),
            };
            if (best == null or found.span > best.?.span) best = found;
        }

        if (obj.get("children")) |children| {
            if (children == .array) {
                if (try searchSymbolTree(ctx, children.array, uri, query)) |found| {
                    if (best == null or found.span > best.?.span) best = found;
                }
            }
        }
    }
    return best;
}

/// How many lines a `range` covers.
fn rangeSpan(range: std.json.Value) i64 {
    const obj = switch (range) {
        .object => |o| o,
        else => return 0,
    };
    const line_of = struct {
        fn get(point: std.json.Value) i64 {
            return switch (point) {
                .object => |p| switch (p.get("line") orelse .null) {
                    .integer => |i| i,
                    else => 0,
                },
                else => 0,
            };
        }
    }.get;
    return line_of(obj.get("end") orelse .null) - line_of(obj.get("start") orelse .null);
}

/// Where a position-based request should point: either the coordinates the
/// caller supplied, or the ones resolved from a symbol name.
const Target = struct {
    uri: []const u8,
    line: i64,
    character: i64,
    /// Set when the position came from a symbol lookup, for the response header.
    resolved: ?ResolvedSymbol = null,
};

fn resolveTarget(ctx: ToolContext, args: std.json.Value) ToolError!Target {
    if (getStringArg(args, "file")) |file| {
        const line = getPositionArg(args, "line") orelse return ToolError.InvalidParams;
        const character = getPositionArg(args, "character") orelse return ToolError.InvalidParams;
        const uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err|
            return docToToolError(err);
        return .{ .uri = uri, .line = line, .character = character };
    }

    const symbol = getStringArg(args, "symbol") orelse return ToolError.InvalidParams;
    const found = try resolveSymbol(ctx, symbol);

    // The declaration has to be open before ZLS will answer about it.
    const path = uri_util.uriToPath(ctx.allocator, found.uri) catch return ToolError.LspError;
    defer ctx.allocator.free(path);
    const uri = ctx.doc_state.ensureOpen(ctx.lsp_client, path, ctx.allocator) catch |err|
        return docToToolError(err);

    return .{ .uri = uri, .line = found.line, .character = found.character, .resolved = found };
}

/// Prefix explaining which declaration a symbol query landed on, so an
/// ambiguous name does not silently answer about the wrong one.
fn writeResolutionNote(w: *std.Io.Writer, target: Target) !void {
    const found = target.resolved orelse return;
    try w.print("{s} ({s}) at {s}:{d}:{d}\n\n", .{
        found.name,
        lsp_types.symbolKindName(found.kind),
        uri_util.stripFilePrefix(found.uri),
        found.line + 1,
        found.character + 1,
    });
}

// ── LSP-backed tool handlers ──

fn handleHover(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const target = try resolveTarget(ctx, args);
    defer ctx.allocator.free(target.uri);

    const HoverParams = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/hover", HoverParams{
        .textDocument = .{ .uri = target.uri },
        .position = .{ .line = target.line, .character = target.character },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    const body = formatHoverResponse(ctx.allocator, response) catch return ToolError.LspError;
    return prependResolution(ctx, target, body);
}

/// Glue the "resolved X at file:line" header onto a tool result.
fn prependResolution(ctx: ToolContext, target: Target, body: []const u8) ToolError![]const u8 {
    if (target.resolved == null) return body;
    defer ctx.allocator.free(body);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer aw.deinit();
    writeResolutionNote(&aw.writer, target) catch return ToolError.OutOfMemory;
    aw.writer.writeAll(body) catch return ToolError.OutOfMemory;
    return aw.toOwnedSlice() catch ToolError.OutOfMemory;
}

fn handleDefinition(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const target = try resolveTarget(ctx, args);
    defer ctx.allocator.free(target.uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/definition", Params{
        .textDocument = .{ .uri = target.uri },
        .position = .{ .line = target.line, .character = target.character },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    const body = formatLocationResponse(ctx.allocator, response) catch return ToolError.LspError;
    return prependResolution(ctx, target, body);
}

fn handleReferences(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    if (getStringArg(args, "file") == null) {
        const symbol = getStringArg(args, "symbol") orelse return ToolError.InvalidParams;
        return referencesBySymbol(ctx, symbol);
    }

    const target = try resolveTarget(ctx, args);
    defer ctx.allocator.free(target.uri);

    const response = try requestReferences(ctx, target.uri, target.line, target.character);
    defer ctx.allocator.free(response);
    return formatLocationResponse(ctx.allocator, response) catch ToolError.LspError;
}

fn requestReferences(ctx: ToolContext, uri: []const u8, line: i64, character: i64) ToolError![]const u8 {
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        context: struct { includeDeclaration: bool = true },
    };
    return ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/references", Params{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = line, .character = character },
        .context = .{},
    }) catch |err| lspToToolError(err);
}

/// Union of the references reported for every declaration of `symbol`.
fn referencesBySymbol(ctx: ToolContext, symbol: []const u8) ToolError![]const u8 {
    const declarations = try resolveSymbolAll(ctx, symbol);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;

    for (declarations) |decl| {
        const path = uri_util.uriToPath(ctx.allocator, decl.uri) catch continue;
        defer ctx.allocator.free(path);
        const uri = ctx.doc_state.ensureOpen(ctx.lsp_client, path, ctx.allocator) catch continue;
        defer ctx.allocator.free(uri);

        const response = try requestReferences(ctx, uri, decl.line, decl.character);
        defer ctx.allocator.free(response);

        const formatted = formatLocationResponse(ctx.allocator, response) catch continue;
        defer ctx.allocator.free(formatted);

        var it = std.mem.splitScalar(u8, formatted, '\n');
        while (it.next()) |entry| {
            if (entry.len == 0 or entry[0] != '/') continue;
            if (seen.contains(entry)) continue;
            const owned = ctx.allocator.dupe(u8, entry) catch return ToolError.OutOfMemory;
            seen.put(ctx.allocator, owned, {}) catch return ToolError.OutOfMemory;
            lines.append(ctx.allocator, owned) catch return ToolError.OutOfMemory;
        }
    }

    if (lines.items.len == 0) return ctx.allocator.dupe(u8, "No references found") catch ToolError.OutOfMemory;

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer aw.deinit();
    const primary = declarations[0];
    aw.writer.print("{s} ({s}) declared at {s}:{d}:{d}", .{
        primary.name,
        lsp_types.symbolKindName(primary.kind),
        uri_util.stripFilePrefix(primary.uri),
        primary.line + 1,
        primary.character + 1,
    }) catch return ToolError.OutOfMemory;
    if (declarations.len > 1) {
        // Aliases are separate declarations; say so rather than pretending the
        // list came from one place.
        aw.writer.print(" (+{d} re-export(s), all searched)", .{declarations.len - 1}) catch
            return ToolError.OutOfMemory;
    }
    aw.writer.writeAll("\n\n") catch return ToolError.OutOfMemory;
    for (lines.items) |entry| {
        aw.writer.print("{s}\n", .{entry}) catch return ToolError.OutOfMemory;
    }
    return aw.toOwnedSlice() catch ToolError.OutOfMemory;
}

fn handleCompletion(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getPositionArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getPositionArg(args, "character") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return docToToolError(err);
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

/// How long to wait for ZLS to push diagnostics after a document is synced.
const diagnostics_timeout_ms: u32 = 3000;

fn handleDiagnostics(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;

    // Syncing the document is what makes ZLS (re)compute diagnostics; a
    // changed document also invalidates whatever was cached for that URI.
    const synced = ctx.doc_state.sync(ctx.lsp_client, file, ctx.allocator) catch |err| return docToToolError(err);
    defer ctx.allocator.free(synced.uri);

    // Diagnostics arrive as notifications, so there is nothing to request —
    // the reader thread caches them and this waits for that to happen.
    const raw = ctx.lsp_client.waitForDiagnostics(ctx.allocator, synced.uri, diagnostics_timeout_ms) catch
        return ToolError.LspError;
    const payload = raw orelse return ctx.allocator.dupe(
        u8,
        "ZLS reported no diagnostics for this file within the timeout.",
    ) catch ToolError.OutOfMemory;
    defer ctx.allocator.free(payload);

    return formatDiagnostics(ctx.allocator, payload) catch return ToolError.LspError;
}

/// Render the cached `diagnostics` array as `line:col: severity: message`.
fn formatDiagnostics(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |a| a,
        else => return allocator.dupe(u8, "No diagnostics"),
    };
    if (items.items.len == 0) return allocator.dupe(u8, "No diagnostics: file is clean.");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    for (items.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const message = switch (obj.get("message") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const severity: ?u32 = switch (obj.get("severity") orelse .null) {
            .integer => |i| if (i >= 0) @intCast(i) else null,
            else => null,
        };

        var line: i64 = 0;
        var character: i64 = 0;
        if (obj.get("range")) |range| {
            if (range == .object) {
                if (range.object.get("start")) |start| {
                    if (start == .object) {
                        line = switch (start.object.get("line") orelse .null) {
                            .integer => |i| i,
                            else => 0,
                        };
                        character = switch (start.object.get("character") orelse .null) {
                            .integer => |i| i,
                            else => 0,
                        };
                    }
                }
            }
        }

        try aw.writer.print("{d}:{d}: {s}: {s}\n", .{
            line + 1,
            character + 1,
            lsp_types.severityName(severity),
            message,
        });
    }
    return try aw.toOwnedSlice();
}

fn handleRename(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const line = getPositionArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getPositionArg(args, "character") orelse return ToolError.InvalidParams;
    const new_name = getStringArg(args, "new_name") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return docToToolError(err);
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

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return docToToolError(err);
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

/// Parameters for `textDocument/codeAction`.
///
/// `diagnostics` is a JSON array by contract. Declaring it as `[]const u8`
/// serializes an empty slice as `""`, which ZLS rejects.
const CodeActionParams = struct {
    textDocument: struct { uri: []const u8 },
    range: struct {
        start: struct { line: i64, character: i64 },
        end: struct { line: i64, character: i64 },
    },
    context: struct {
        diagnostics: []const lsp_types.Diagnostic = &.{},
    },
};

fn handleCodeAction(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const start_line = getPositionArg(args, "start_line") orelse return ToolError.InvalidParams;
    const start_char = getPositionArg(args, "start_char") orelse return ToolError.InvalidParams;
    const end_line = getPositionArg(args, "end_line") orelse return ToolError.InvalidParams;
    const end_char = getPositionArg(args, "end_char") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return docToToolError(err);
    defer ctx.allocator.free(file_uri);

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/codeAction", CodeActionParams{
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
    const line = getPositionArg(args, "line") orelse return ToolError.InvalidParams;
    const char = getPositionArg(args, "character") orelse return ToolError.InvalidParams;

    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err| return docToToolError(err);
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

// ── Inlay hints and type definition ──

fn handleTypeDefinition(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const target = try resolveTarget(ctx, args);
    defer ctx.allocator.free(target.uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };
    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/typeDefinition", Params{
        .textDocument = .{ .uri = target.uri },
        .position = .{ .line = target.line, .character = target.character },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    const body = formatLocationResponse(ctx.allocator, response) catch return ToolError.LspError;
    return prependResolution(ctx, target, body);
}

fn handleInlayHints(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const file = getStringArg(args, "file") orelse return ToolError.InvalidParams;
    const uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch |err|
        return docToToolError(err);
    defer ctx.allocator.free(uri);

    const source = readWorkspaceFile(ctx, file) catch |err| switch (err) {
        error.FileNotFound => return ToolError.FileNotFound,
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return ToolError.FileReadError,
    };
    defer ctx.allocator.free(source);
    const last_line = std.mem.count(u8, source, "\n");

    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: struct {
            start: struct { line: i64, character: i64 },
            end: struct { line: i64, character: i64 },
        },
    };
    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/inlayHint", Params{
        .textDocument = .{ .uri = uri },
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = @intCast(last_line + 1), .character = 0 },
        },
    }) catch |err| return lspToToolError(err);
    defer ctx.allocator.free(response);

    return formatInlayHints(ctx.allocator, response, source) catch return ToolError.LspError;
}

/// Render hints back into the source line they annotate, so the reply reads
/// like the code rather than like a coordinate list.
fn formatInlayHints(allocator: std.mem.Allocator, response: []const u8, source: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const hints = switch (parsed.value) {
        .object => |o| switch (o.get("result") orelse .null) {
            .array => |a| a,
            else => return allocator.dupe(u8, "No inlay hints for this file"),
        },
        else => return allocator.dupe(u8, "Invalid response"),
    };
    if (hints.items.len == 0) return allocator.dupe(u8, "No inlay hints: nothing in this file has an inferred type to show.");

    // Collect per line, then splice right to left so earlier insertions do not
    // shift the offsets of later ones.
    const Hint = struct { line: usize, character: usize, label: []const u8 };
    var collected: std.ArrayList(Hint) = .empty;
    defer collected.deinit(allocator);

    for (hints.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const position = switch (obj.get("position") orelse .null) {
            .object => |p| p,
            else => continue,
        };
        const line = switch (position.get("line") orelse .null) {
            .integer => |i| if (i >= 0) @as(usize, @intCast(i)) else continue,
            else => continue,
        };
        const character = switch (position.get("character") orelse .null) {
            .integer => |i| if (i >= 0) @as(usize, @intCast(i)) else continue,
            else => continue,
        };
        const label = switch (obj.get("label") orelse .null) {
            .string => |l| l,
            // The array form is a list of parts; the first carries the text.
            .array => |parts| if (parts.items.len > 0) switch (parts.items[0]) {
                .object => |part| switch (part.get("value") orelse .null) {
                    .string => |v| v,
                    else => continue,
                },
                else => continue,
            } else continue,
            else => continue,
        };
        try collected.append(allocator, .{ .line = line, .character = character, .label = label });
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (line_iter.next()) |line_text| : (line_no += 1) {
        var on_this_line: std.ArrayList(Hint) = .empty;
        defer on_this_line.deinit(allocator);
        for (collected.items) |h| {
            if (h.line == line_no) try on_this_line.append(allocator, h);
        }
        if (on_this_line.items.len == 0) continue;

        std.mem.sort(Hint, on_this_line.items, {}, struct {
            fn rightToLeft(_: void, a: Hint, b: Hint) bool {
                return a.character > b.character;
            }
        }.rightToLeft);

        var spliced: std.ArrayList(u8) = .empty;
        defer spliced.deinit(allocator);
        try spliced.appendSlice(allocator, line_text);
        for (on_this_line.items) |h| {
            const at = @min(h.character, spliced.items.len);
            try spliced.insertSlice(allocator, at, h.label);
        }
        try aw.writer.print("{d}: {s}\n", .{ line_no + 1, std.mem.trim(u8, spliced.items, " \t\r") });
    }

    if (aw.written().len == 0) return allocator.dupe(u8, "No inlay hints for this file");
    return aw.toOwnedSlice();
}

// ── AST queries ──

fn readWorkspaceFile(ctx: ToolContext, file: []const u8) ![:0]u8 {
    const abs = try uri_util.resolvePath(ctx.allocator, ctx.workspace.root_path, file);
    defer ctx.allocator.free(abs);
    const contents = std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.allocator, std.Io.Limit.limited(max_source_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.FileReadError,
    };
    defer ctx.allocator.free(contents);
    return ctx.allocator.dupeSentinel(u8, contents, 0);
}

/// Every `.zig` file in the workspace, workspace-relative. Caller frees.
fn workspaceZigFiles(ctx: ToolContext) ToolError![]const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.workspace.root_path, .{ .iterate = true }) catch
        return ToolError.FileReadError;
    defer dir.close(ctx.io);

    var walker = dir.walk(ctx.allocator) catch return ToolError.OutOfMemory;
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(ctx.allocator);

    while (walker.next(ctx.io) catch null) |entry| {
        if (files.items.len >= max_scanned_files) break;
        if (entry.kind == .directory) {
            if (isSkippedDir(entry.basename)) walker.leave(ctx.io);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const owned = ctx.allocator.dupe(u8, entry.path) catch return ToolError.OutOfMemory;
        files.append(ctx.allocator, owned) catch return ToolError.OutOfMemory;
    }
    return files.toOwnedSlice(ctx.allocator) catch ToolError.OutOfMemory;
}

/// Say out loud how much of the tree was not analyzed. A scan that silently
/// drops unreadable or unparsable files and then answers "nothing found"
/// reports a clean bill of health it did not earn.
fn writeSkipNote(aw: *std.Io.Writer.Allocating, skipped: usize, total_files: usize) ToolError!void {
    if (skipped == 0) return;
    aw.writer.print(
        "\nIncomplete: {d} of {d} file(s) could not be read or parsed and were not analyzed.\n",
        .{ skipped, total_files },
    ) catch return ToolError.OutOfMemory;
}

fn handleAstQuery(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const shape_name = getStringArg(args, "shape") orelse return ToolError.InvalidParams;
    const shape = ast_tools.Shape.fromString(shape_name) orelse return ToolError.InvalidParams;

    const files: []const []const u8 = if (getStringArg(args, "file")) |one|
        &.{one}
    else
        try workspaceZigFiles(ctx);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer aw.deinit();
    var total: usize = 0;
    var skipped: usize = 0;

    for (files) |file| {
        const source = readWorkspaceFile(ctx, file) catch {
            skipped += 1;
            continue;
        };
        defer ctx.allocator.free(source);

        var matches: std.ArrayList(ast_tools.Match) = .empty;
        defer {
            for (matches.items) |m| ctx.allocator.free(m.text);
            matches.deinit(ctx.allocator);
        }
        ast_tools.findShape(ctx.allocator, source, shape, &matches) catch {
            skipped += 1;
            continue;
        };

        for (matches.items) |m| {
            total += 1;
            aw.writer.print("{s}:{d}:{d}: {s}\n", .{ file, m.line, m.column, m.text }) catch
                return ToolError.OutOfMemory;
        }
    }

    aw.writer.print("\n{d} occurrence(s) of: {s}\n", .{ total, shape.describe() }) catch
        return ToolError.OutOfMemory;
    // Never report a clean result while quietly having skipped part of the
    // tree: "no matches" and "no matches among what I could read" are
    // different answers.
    try writeSkipNote(&aw, skipped, files.len);
    return aw.toOwnedSlice() catch ToolError.OutOfMemory;
}

fn handleUnusedPrivate(ctx: ToolContext, args: std.json.Value) ToolError![]const u8 {
    const files: []const []const u8 = if (getStringArg(args, "file")) |one|
        &.{one}
    else
        try workspaceZigFiles(ctx);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer aw.deinit();
    var total: usize = 0;
    var skipped: usize = 0;

    for (files) |file| {
        const source = readWorkspaceFile(ctx, file) catch {
            skipped += 1;
            continue;
        };
        defer ctx.allocator.free(source);

        var found: std.ArrayList(ast_tools.UnusedDecl) = .empty;
        defer {
            for (found.items) |d| ctx.allocator.free(d.name);
            found.deinit(ctx.allocator);
        }
        ast_tools.findUnusedPrivate(ctx.allocator, source, &found) catch {
            skipped += 1;
            continue;
        };

        for (found.items) |d| {
            total += 1;
            aw.writer.print("{s}:{d}:{d}: private {s} `{s}` is never referenced\n", .{
                file, d.line, d.column, d.kind, d.name,
            }) catch return ToolError.OutOfMemory;
        }
    }

    if (total == 0) {
        aw.writer.writeAll("No unused private declarations") catch return ToolError.OutOfMemory;
    }
    try writeSkipNote(&aw, skipped, files.len);
    return aw.toOwnedSlice() catch ToolError.OutOfMemory;
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
    const path = uri_util.stripFilePrefix(uri_str);

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
                const preview = truncateUtf8(text, 80);
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
                const path = uri_util.stripFilePrefix(entry.key_ptr.*);
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
                        const path = uri_util.stripFilePrefix(loc_uri.string);
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

fn lspToToolError(err: anytype) ToolError {
    return switch (err) {
        error.NotConnected => ToolError.NotConnected,
        error.RequestTimeout => ToolError.RequestTimeout,
        error.NoResponse => ToolError.NoResponse,
        else => ToolError.LspError,
    };
}

/// Map a document-sync failure. Reporting everything as `FileNotFound` (the
/// old behaviour) hid `NotConnected`, which is what drives the ZLS reconnect.
fn docToToolError(err: anytype) ToolError {
    return switch (err) {
        error.FileNotFound => ToolError.FileNotFound,
        error.FileReadError => ToolError.FileReadError,
        error.NotConnected => ToolError.NotConnected,
        error.OutOfMemory => ToolError.OutOfMemory,
        else => ToolError.LspError,
    };
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


test "getIntArg rejects out-of-range and non-finite floats" {
    const alloc = std.testing.allocator;
    // `@intFromFloat` on any of these is illegal behaviour, so they must be
    // rejected before the conversion — a client could otherwise crash the
    // server with one message.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"huge":1e300,"tiny":-1e300,"ok":7.0}
    , .{});
    defer parsed.deinit();

    try std.testing.expect(getIntArg(parsed.value, "huge") == null);
    try std.testing.expect(getIntArg(parsed.value, "tiny") == null);
    try std.testing.expectEqual(@as(i64, 7), getIntArg(parsed.value, "ok").?);
}

test "floatToInt boundaries" {
    try std.testing.expectEqual(@as(i64, 0), floatToInt(0.0).?);
    try std.testing.expectEqual(@as(i64, -1), floatToInt(-1.5).?);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), floatToInt(-9223372036854775808.0).?);
    try std.testing.expect(floatToInt(9223372036854775808.0) == null);
    try std.testing.expect(floatToInt(std.math.inf(f64)) == null);
    try std.testing.expect(floatToInt(std.math.nan(f64)) == null);
}

test "getPositionArg rejects negative positions" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"line":-1,"character":0}
    , .{});
    defer parsed.deinit();

    try std.testing.expect(getPositionArg(parsed.value, "line") == null);
    try std.testing.expectEqual(@as(i64, 0), getPositionArg(parsed.value, "character").?);
}

test "truncateUtf8 never splits a codepoint" {
    try std.testing.expectEqualStrings("abc", truncateUtf8("abc", 10));
    try std.testing.expectEqualStrings("ab", truncateUtf8("abc", 2));
    // "é" is two bytes: cutting at 1 must drop it entirely.
    try std.testing.expectEqualStrings("a", truncateUtf8("aé", 2));
    try std.testing.expectEqualStrings("aé", truncateUtf8("aé", 3));
    // Four-byte codepoint at every possible cut point.
    const emoji = "x🙂";
    for (0..emoji.len + 1) |max| {
        const cut = truncateUtf8(emoji, max);
        try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    }
}

test "codeAction params serialize diagnostics as an array" {
    const alloc = std.testing.allocator;
    const params = CodeActionParams{
        .textDocument = .{ .uri = "file:///a.zig" },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .context = .{},
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.write(params);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"diagnostics\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"diagnostics\":\"\"") == null);
}

test "formatDiagnostics renders one line per diagnostic" {
    const alloc = std.testing.allocator;
    const payload =
        \\[{"range":{"start":{"line":9,"character":4},"end":{"line":9,"character":8}},"severity":1,"message":"expected ';'"},
        \\ {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":2,"message":"unused variable"}]
    ;
    const out = try formatDiagnostics(alloc, payload);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "10:5: Error: expected ';'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1:1: Warning: unused variable") != null);
}

test "formatDiagnostics on an empty array reports a clean file" {
    const alloc = std.testing.allocator;
    const out = try formatDiagnostics(alloc, "[]");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("No diagnostics: file is clean.", out);
}

test "formatDiagnostics tolerates malformed entries" {
    const alloc = std.testing.allocator;
    const out = try formatDiagnostics(alloc,
        \\[1,"two",{"message":"kept"},{"no_message":true}]
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "kept") != null);
}

test "registerAll registers every tool exactly once" {
    const alloc = std.testing.allocator;
    var reg = registry.Registry.init(alloc);
    defer reg.deinit();

    try registerAll(&reg);
    try std.testing.expectEqual(@as(u32, 14), reg.entries.count());
    try std.testing.expect(reg.getHandler("zig_hover") != null);
    try std.testing.expect(reg.getHandler("zig_diagnostics") != null);

    // Wrappers around shell commands are gone on purpose: they competed with
    // Bash and never won.
    for ([_][]const u8{ "zig_build", "zig_test", "zig_format", "zig_version", "zig_check", "zig_manage" }) |gone| {
        try std.testing.expect(reg.getHandler(gone) == null);
    }

    // Every schema must be an object: MCP clients discard tools whose
    // `properties` is null.
    var it = reg.entries.iterator();
    while (it.next()) |entry| {
        try std.testing.expect(entry.value_ptr.definition.inputSchema.properties == .object);
    }
}

test "registerAll survives allocation failure without leaking" {
    const alloc = std.testing.allocator;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = i });
        var reg = registry.Registry.init(failing.allocator());
        defer reg.deinit();
        registerAll(&reg) catch {};
    }
}

// ── End-to-end tool tests ──
//
// These drive a real `LspClient` against a fake ZLS, so they cover the whole
// path a tool call takes: document sync, request serialization, and response
// formatting. Everything below the fake is the production code.

const test_zls = @import("../test_zls.zig");
const DocumentState = @import("../state/documents.zig").DocumentState;
const Workspace = @import("../state/workspace.zig").Workspace;
const test_util = @import("../testing.zig");

const ToolFixture = struct {
    fake: test_zls.FakeZls,
    ws: test_util.TmpWorkspace,
    workspace: Workspace,
    docs: DocumentState,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !ToolFixture {
        var ws = try test_util.TmpWorkspace.init(alloc);
        errdefer ws.deinit();
        return .{
            .fake = try test_zls.FakeZls.init(alloc),
            .ws = ws,
            .workspace = try Workspace.init(alloc, ws.root),
            // SAFETY: assigned by `start`, which borrows `workspace.root_path`
            // and so needs this struct to be at its final address.
            .docs = undefined,
            .alloc = alloc,
        };
    }

    fn start(self: *ToolFixture) !void {
        try self.fake.start();
        self.docs = DocumentState.init(self.alloc, self.workspace.root_path, test_util.io());
    }

    fn ctx(self: *ToolFixture, allocator: std.mem.Allocator) ToolContext {
        return .{
            .lsp_client = &self.fake.client,
            .doc_state = &self.docs,
            .workspace = &self.workspace,
            .allocator = allocator,
            .io = test_util.io(),
        };
    }

    fn deinit(self: *ToolFixture) void {
        self.docs.deinit();
        self.fake.deinit();
        self.workspace.deinit();
        self.ws.deinit();
    }
};

/// Build `{"file": ..., "line": ..., "character": ...}` for a handler call.
fn positionArgs(arena: std.mem.Allocator, file: []const u8, line: i64, character: i64) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "file", .{ .string = file });
    try obj.put(arena, "line", .{ .integer = line });
    try obj.put(arena, "character", .{ .integer = character });
    return .{ .object = obj };
}

/// Drain the didOpen/didChange notification the document sync emits, then
/// answer the request that follows.
fn serveOne(fake: *test_zls.FakeZls, alloc: std.mem.Allocator, result: []const u8) !void {
    while (true) {
        const msg = (try fake.nextRequest(alloc)) orelse return error.NoRequest;
        defer alloc.free(msg);

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, msg, .{});
        defer parsed.deinit();
        const id = parsed.value.object.get("id") orelse continue; // notification
        const reply = try std.fmt.allocPrint(
            alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
            .{ id.integer, result },
        );
        defer alloc.free(reply);
        try fake.reply(reply);
        return;
    }
}

test "zig_hover syncs the document and formats the hover" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("a.zig", "const a = 1;");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const args = try positionArgs(arena.allocator(), "a.zig", 0, 6);

    const server = try std.Thread.spawn(.{}, serveOne, .{
        &fx.fake, alloc,
        \\{"contents":{"kind":"markdown","value":"const a: comptime_int"}}
    });
    defer server.join();

    const out = try handleHover(fx.ctx(arena.allocator()), args);
    try std.testing.expectEqualStrings("const a: comptime_int", out);
}

test "an edited file is resynced before the next request" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("a.zig", "const a = 1;");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const args = try positionArgs(arena.allocator(), "a.zig", 0, 6);

    const first = try std.Thread.spawn(.{}, serveOne, .{ &fx.fake, alloc, "{\"contents\":\"one\"}" });
    const out1 = try handleHover(fx.ctx(arena.allocator()), args);
    first.join();
    try std.testing.expectEqualStrings("one", out1);

    // The file changes on disk. Without a didChange, ZLS would keep answering
    // from the original text — the bug this guards.
    try fx.ws.writeFile("a.zig", "const a = 2222;");

    const second = try std.Thread.spawn(.{}, serveOne, .{ &fx.fake, alloc, "{\"contents\":\"two\"}" });
    const out2 = try handleHover(fx.ctx(arena.allocator()), args);
    second.join();
    try std.testing.expectEqualStrings("two", out2);

    // Version 2 means exactly one didChange was sent for the one edit.
    const uri = try fx.workspace.fileUri(alloc, "a.zig");
    defer alloc.free(uri);
    try std.testing.expectEqual(@as(i64, 2), fx.docs.open_docs.get(uri).?.version);
}

test "zig_code_action sends diagnostics as an array on the wire" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("a.zig", "const a = 1;");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena.allocator(), "file", .{ .string = "a.zig" });
    for ([_][]const u8{ "start_line", "start_char", "end_line", "end_char" }) |key| {
        try obj.put(arena.allocator(), key, .{ .integer = 0 });
    }

    const Capture = struct {
        fn run(fake: *test_zls.FakeZls, a: std.mem.Allocator, out: *[]const u8) !void {
            while (true) {
                const msg = (try fake.nextRequest(a)) orelse return error.NoRequest;
                const parsed = try std.json.parseFromSlice(std.json.Value, a, msg, .{});
                defer parsed.deinit();
                if (parsed.value.object.get("id")) |id| {
                    out.* = msg;
                    const reply = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id.integer});
                    defer a.free(reply);
                    try fake.reply(reply);
                    return;
                }
                a.free(msg);
            }
        }
    };
    var request: []const u8 = "";
    const server = try std.Thread.spawn(.{}, Capture.run, .{ &fx.fake, alloc, &request });

    const out = try handleCodeAction(fx.ctx(arena.allocator()), .{ .object = obj });
    server.join();
    defer alloc.free(request);

    try std.testing.expectEqualStrings("No code actions available", out);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"diagnostics\":[]") != null);
}

test "zig_diagnostics returns what ZLS published" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("a.zig", "const a = ;");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena.allocator(), "file", .{ .string = "a.zig" });

    const uri = try fx.workspace.fileUri(alloc, "a.zig");
    defer alloc.free(uri);

    const Publisher = struct {
        fn run(fake: *test_zls.FakeZls, a: std.mem.Allocator, doc_uri: []const u8) !void {
            // Wait for the didOpen, then push diagnostics like ZLS would.
            const msg = (try fake.nextRequest(a)) orelse return error.NoRequest;
            defer a.free(msg);
            const note = try std.fmt.allocPrint(a,
                \\{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"{s}","diagnostics":[{{"range":{{"start":{{"line":0,"character":10}},"end":{{"line":0,"character":11}}}},"severity":1,"message":"expected expression"}}]}}}}
            , .{doc_uri});
            defer a.free(note);
            try fake.reply(note);
        }
    };
    const publisher = try std.Thread.spawn(.{}, Publisher.run, .{ &fx.fake, alloc, uri });
    defer publisher.join();

    const out = try handleDiagnostics(fx.ctx(arena.allocator()), .{ .object = obj });
    try std.testing.expectEqualStrings("1:11: Error: expected expression\n", out);
}

test "a tool reports NotConnected once ZLS is gone" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("a.zig", "const a = 1;");

    fx.fake.kill();
    while (fx.fake.client.isConnected()) {
        test_util.io().sleep(.fromMilliseconds(5), .awake) catch break;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const args = try positionArgs(arena.allocator(), "a.zig", 0, 6);

    // Must be NotConnected, not FileNotFound: the server keys its reconnect
    // attempt off this error.
    try std.testing.expectError(ToolError.NotConnected, handleHover(fx.ctx(arena.allocator()), args));
}

test "symbol-addressable tools accept a bare symbol name" {
    // The whole point of the `symbol` form: no file, no coordinates. A schema
    // that still demanded them would defeat it.
    const alloc = std.testing.allocator;
    var reg = registry.Registry.init(alloc);
    defer reg.deinit();
    try registerAll(&reg);

    var it = reg.entries.iterator();
    var checked: usize = 0;
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const symbol_addressable = std.mem.eql(u8, name, "zig_hover") or
            std.mem.eql(u8, name, "zig_definition") or
            std.mem.eql(u8, name, "zig_references");
        if (!symbol_addressable) continue;
        checked += 1;

        const schema = entry.value_ptr.definition.inputSchema;
        try std.testing.expect(schema.properties.object.get("symbol") != null);
        // Nothing may be mandatory, or the symbol-only call would be invalid.
        try std.testing.expect(schema.required == null);
    }
    try std.testing.expectEqual(@as(usize, 3), checked);
}

/// Answer `documentSymbol` for however many candidate files the resolver
/// opens, then hand back control. The resolver drives the count, so the
/// responder must not assume a fixed number of requests.
fn serveDocumentSymbols(fake: *test_zls.FakeZls, a: std.mem.Allocator, replies: []const []const u8) !void {
    for (replies) |reply| try serveOne(fake, a, reply);
}

test "resolveSymbol prefers the declaration over a re-export" {
    // `const X = @import("..").X;` is its own declaration and spans one line.
    // Ranking by span keeps a symbol query off the alias, which matters
    // because ZLS answers about whichever declaration is under the cursor.
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("alias.zig", "const PosixMutex = @import(\"sync.zig\").PosixMutex;\n");
    try fx.ws.writeFile("sync.zig", "pub const PosixMutex = struct {\n    inner: u8,\n};\n");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // Both files contain the name, so both get a documentSymbol round trip.
    // The single-line one must lose regardless of which is served first.
    const one_line =
        \\[{"name":"PosixMutex","kind":14,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":50}},"selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":16}}}]
    ;
    const multi_line =
        \\[{"name":"PosixMutex","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":2}},"selectionRange":{"start":{"line":0,"character":10},"end":{"line":0,"character":20}}}]
    ;
    const responder = try std.Thread.spawn(.{}, serveDocumentSymbols, .{
        &fx.fake, alloc, &[_][]const u8{ one_line, multi_line },
    });
    defer responder.join();

    const found = try resolveSymbol(fx.ctx(arena.allocator()), "PosixMutex");
    try std.testing.expectEqualStrings("PosixMutex", found.name);
    try std.testing.expectEqual(@as(i64, 2), found.span);
    try std.testing.expectEqual(@as(u32, 23), found.kind); // Struct, not Constant
}

test "resolveSymbol ignores a name that only appears in prose" {
    // The shortlist is textual, but the match is semantic: a mention in a
    // comment never reaches a document symbol tree.
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("notes.zig", "// TODO: replace PosixMutex here\nconst x = 1;\n");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const responder = try std.Thread.spawn(.{}, serveDocumentSymbols, .{
        &fx.fake, alloc, &[_][]const u8{
            \\[{"name":"x","kind":14,"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":12}},"selectionRange":{"start":{"line":1,"character":6},"end":{"line":1,"character":7}}}]
        },
    });
    defer responder.join();

    try std.testing.expectError(
        ToolError.SymbolNotFound,
        resolveSymbol(fx.ctx(arena.allocator()), "PosixMutex"),
    );
}

test "resolveSymbol reports an unknown name without any LSP traffic" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("a.zig", "const a = 1;\n");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // No file contains the name, so no candidate is opened at all.
    try std.testing.expectError(
        ToolError.SymbolNotFound,
        resolveSymbol(fx.ctx(arena.allocator()), "NoSuchThing"),
    );
}

test "resolveSymbol finds nested declarations" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("s.zig", "pub const Outer = struct {\n    pub fn inner() void {}\n};\n");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const responder = try std.Thread.spawn(.{}, serveDocumentSymbols, .{
        &fx.fake, alloc, &[_][]const u8{
            \\[{"name":"Outer","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":2}},"selectionRange":{"start":{"line":0,"character":10},"end":{"line":0,"character":15}},"children":[{"name":"inner","kind":12,"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":26}},"selectionRange":{"start":{"line":1,"character":11},"end":{"line":1,"character":16}}}]}]
        },
    });
    defer responder.join();

    const found = try resolveSymbol(fx.ctx(arena.allocator()), "inner");
    try std.testing.expectEqualStrings("inner", found.name);
    try std.testing.expectEqual(@as(i64, 1), found.line);
    try std.testing.expectEqual(@as(i64, 11), found.character); // selectionRange, not range
}

test "zig_definition by symbol needs no file or coordinates" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("sync.zig", "pub const PosixMutex = struct {\n    inner: u8,\n};\n");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const abs = try fx.ws.path("sync.zig");
    defer alloc.free(abs);
    const uri = try uri_util.pathToUri(alloc, abs);
    defer alloc.free(uri);

    const Responder = struct {
        fn run(fake: *test_zls.FakeZls, a: std.mem.Allocator, doc_uri: []const u8) !void {
            // 1. documentSymbol locates the declaration...
            try serveOne(fake, a,
                \\[{"name":"PosixMutex","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":2}},"selectionRange":{"start":{"line":0,"character":10},"end":{"line":0,"character":20}}}]
            );
            // 2. ...then the definition request uses the resolved position.
            const location = try std.fmt.allocPrint(a,
                \\{{"uri":"{s}","range":{{"start":{{"line":0,"character":10}},"end":{{"line":0,"character":20}}}}}}
            , .{doc_uri});
            defer a.free(location);
            try serveOne(fake, a, location);
        }
    };
    const responder = try std.Thread.spawn(.{}, Responder.run, .{ &fx.fake, alloc, uri });
    defer responder.join();

    var args: std.json.ObjectMap = .empty;
    try args.put(arena.allocator(), "symbol", .{ .string = "PosixMutex" });

    const out = try handleDefinition(fx.ctx(arena.allocator()), .{ .object = args });
    // The header names the declaration the query landed on, so an ambiguous
    // name cannot silently answer about the wrong one.
    try std.testing.expect(std.mem.startsWith(u8, out, "PosixMutex (Struct) at "));
    try std.testing.expect(std.mem.indexOf(u8, out, "sync.zig:1:11") != null);
}

test "a position call still works and adds no resolution header" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("a.zig", "const a = 1;\n");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const args = try positionArgs(arena.allocator(), "a.zig", 0, 6);

    const responder = try std.Thread.spawn(.{}, serveOne, .{ &fx.fake, alloc, "{\"contents\":\"plain\"}" });
    defer responder.join();

    const out = try handleHover(fx.ctx(arena.allocator()), args);
    try std.testing.expectEqualStrings("plain", out);
}

test "a symbol call with neither symbol nor position is rejected" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var empty: std.json.ObjectMap = .empty;
    try empty.put(arena.allocator(), "unrelated", .{ .string = "x" });

    try std.testing.expectError(
        ToolError.InvalidParams,
        handleHover(fx.ctx(arena.allocator()), .{ .object = empty }),
    );
}

test "a scan that skipped files says so instead of reporting a clean result" {
    // A silent `catch continue` over an unreadable file plus a "No matches"
    // verdict is a clean bill of health the scan did not earn.
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var args: std.json.ObjectMap = .empty;
    try args.put(arena.allocator(), "shape", .{ .string = "empty_catch" });
    try args.put(arena.allocator(), "file", .{ .string = "does-not-exist.zig" });

    const out = try handleAstQuery(fx.ctx(arena.allocator()), .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, out, "Incomplete: 1 of 1") != null);
}

test "an unknown shape is rejected rather than silently matching nothing" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena.allocator(), "shape", .{ .string = "no_such_shape" });

    try std.testing.expectError(
        ToolError.InvalidParams,
        handleAstQuery(fx.ctx(arena.allocator()), .{ .object = args }),
    );
}

test "ast query finds a shape a regex would miss and skips one it would falsely match" {
    const alloc = std.testing.allocator;
    var fx = try ToolFixture.init(alloc);
    try fx.start();
    defer fx.deinit();
    try fx.ws.writeFile("s.zig",
        \\// foo() catch {} in a comment
        \\fn a() void {
        \\    bar() catch {
        \\    };
        \\}
    );

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena.allocator(), "shape", .{ .string = "empty_catch" });
    try args.put(arena.allocator(), "file", .{ .string = "s.zig" });

    const out = try handleAstQuery(fx.ctx(arena.allocator()), .{ .object = args });
    // The multi-line form is found; the comment is not.
    try std.testing.expect(std.mem.indexOf(u8, out, "s.zig:3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 occurrence") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Incomplete") == null);
}
