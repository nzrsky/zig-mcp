const std = @import("std");

/// LSP Position (0-based line and character).
pub const Position = struct {
    line: u32,
    character: u32,
};

/// LSP Range.
pub const Range = struct {
    start: Position,
    end: Position,
};

/// LSP Location.
pub const Location = struct {
    uri: []const u8,
    range: Range,
};

/// LSP TextDocumentIdentifier.
pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

/// LSP TextDocumentPositionParams.
pub const TextDocumentPositionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};

/// LSP TextDocumentItem (for didOpen).
pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i64,
    text: []const u8,
};

/// LSP VersionedTextDocumentIdentifier.
pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i64,
};

/// LSP DidOpenTextDocumentParams.
pub const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem,
};

/// LSP DidCloseTextDocumentParams.
pub const DidCloseTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

/// LSP Diagnostic.
pub const Diagnostic = struct {
    range: Range,
    severity: ?u32 = null,
    code: ?std.json.Value = null,
    source: ?[]const u8 = null,
    message: []const u8,
};

/// LSP PublishDiagnosticsParams (received from ZLS as a notification).
pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const Diagnostic,
};

/// LSP Hover result.
pub const Hover = struct {
    contents: HoverContents,
    range: ?Range = null,
};

pub const HoverContents = union(enum) {
    markup: MarkupContent,
    string: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !HoverContents {
        // Hover contents can be a string or a MarkupContent object.
        const token = try source.peekNextTokenType();
        return switch (token) {
            .string => .{ .string = try std.json.innerParse([]const u8, allocator, source, options) },
            .object_begin => .{ .markup = try std.json.innerParse(MarkupContent, allocator, source, options) },
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonStringify(self: HoverContents, jw: anytype) !void {
        switch (self) {
            .markup => |m| try jw.write(m),
            .string => |s| try jw.write(s),
        }
    }

    pub fn text(self: HoverContents) []const u8 {
        return switch (self) {
            .markup => |m| m.value,
            .string => |s| s,
        };
    }
};

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

/// LSP CompletionItem.
pub const CompletionItem = struct {
    label: []const u8,
    kind: ?u32 = null,
    detail: ?[]const u8 = null,
    documentation: ?std.json.Value = null,
    insertText: ?[]const u8 = null,
};

/// LSP CompletionList.
pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

/// LSP DocumentSymbol.
pub const DocumentSymbol = struct {
    name: []const u8,
    kind: u32,
    range: Range,
    selectionRange: Range,
    detail: ?[]const u8 = null,
    children: ?[]const DocumentSymbol = null,
};

/// LSP SymbolInformation (from workspace/symbol).
pub const SymbolInformation = struct {
    name: []const u8,
    kind: u32,
    location: Location,
    containerName: ?[]const u8 = null,
};

/// LSP WorkspaceEdit.
pub const WorkspaceEdit = struct {
    changes: ?std.json.Value = null, // uri -> TextEdit[]
    documentChanges: ?std.json.Value = null,
};

/// LSP TextEdit.
pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

/// LSP SignatureHelp.
pub const SignatureHelp = struct {
    signatures: []const SignatureInformation,
    activeSignature: ?u32 = null,
    activeParameter: ?u32 = null,
};

pub const SignatureInformation = struct {
    label: []const u8,
    documentation: ?std.json.Value = null,
    parameters: ?[]const ParameterInformation = null,
};

pub const ParameterInformation = struct {
    label: std.json.Value, // string or [number, number]
    documentation: ?std.json.Value = null,
};

/// LSP CodeAction.
pub const CodeAction = struct {
    title: []const u8,
    kind: ?[]const u8 = null,
    edit: ?WorkspaceEdit = null,
    command: ?Command = null,
};

pub const Command = struct {
    title: []const u8,
    command: []const u8,
    arguments: ?std.json.Value = null,
};

/// Map symbol kind number to a human-readable string.
pub fn symbolKindName(kind: u32) []const u8 {
    return switch (kind) {
        1 => "File",
        2 => "Module",
        3 => "Namespace",
        4 => "Package",
        5 => "Class",
        6 => "Method",
        7 => "Property",
        8 => "Field",
        9 => "Constructor",
        10 => "Enum",
        11 => "Interface",
        12 => "Function",
        13 => "Variable",
        14 => "Constant",
        15 => "String",
        16 => "Number",
        17 => "Boolean",
        18 => "Array",
        19 => "Object",
        20 => "Key",
        21 => "Null",
        22 => "EnumMember",
        23 => "Struct",
        24 => "Event",
        25 => "Operator",
        26 => "TypeParameter",
        else => "Unknown",
    };
}

/// Map diagnostic severity number to string.
pub fn severityName(severity: ?u32) []const u8 {
    return switch (severity orelse 0) {
        1 => "Error",
        2 => "Warning",
        3 => "Information",
        4 => "Hint",
        else => "Unknown",
    };
}

// ── Tests ──

test "symbolKindName known kinds" {
    try std.testing.expectEqualStrings("File", symbolKindName(1));
    try std.testing.expectEqualStrings("Function", symbolKindName(12));
    try std.testing.expectEqualStrings("Struct", symbolKindName(23));
    try std.testing.expectEqualStrings("Constant", symbolKindName(14));
    try std.testing.expectEqualStrings("Field", symbolKindName(8));
    try std.testing.expectEqualStrings("EnumMember", symbolKindName(22));
    try std.testing.expectEqualStrings("Variable", symbolKindName(13));
}

test "symbolKindName unknown kind" {
    try std.testing.expectEqualStrings("Unknown", symbolKindName(0));
    try std.testing.expectEqualStrings("Unknown", symbolKindName(99));
    try std.testing.expectEqualStrings("Unknown", symbolKindName(255));
}

test "severityName known severities" {
    try std.testing.expectEqualStrings("Error", severityName(1));
    try std.testing.expectEqualStrings("Warning", severityName(2));
    try std.testing.expectEqualStrings("Information", severityName(3));
    try std.testing.expectEqualStrings("Hint", severityName(4));
}

test "severityName null and unknown" {
    try std.testing.expectEqualStrings("Unknown", severityName(null));
    try std.testing.expectEqualStrings("Unknown", severityName(0));
    try std.testing.expectEqualStrings("Unknown", severityName(100));
}

test "HoverContents text from markup" {
    const hc = HoverContents{ .markup = .{ .value = "fn main() void" } };
    try std.testing.expectEqualStrings("fn main() void", hc.text());
}

test "HoverContents text from string" {
    const hc = HoverContents{ .string = "some hover text" };
    try std.testing.expectEqualStrings("some hover text", hc.text());
}

test "HoverContents markup JSON roundtrip" {
    const alloc = std.testing.allocator;
    const input = "{\"kind\":\"markdown\",\"value\":\"hello world\"}";
    const parsed = try std.json.parseFromSlice(HoverContents, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello world", parsed.value.text());
}

test "HoverContents string JSON roundtrip" {
    const alloc = std.testing.allocator;
    const input = "\"plain hover\"";
    const parsed = try std.json.parseFromSlice(HoverContents, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("plain hover", parsed.value.text());
}

test "Position and Range structs" {
    const pos = Position{ .line = 10, .character = 5 };
    try std.testing.expectEqual(@as(u32, 10), pos.line);
    try std.testing.expectEqual(@as(u32, 5), pos.character);

    const range = Range{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 20 },
    };
    try std.testing.expectEqual(@as(u32, 1), range.start.line);
    try std.testing.expectEqual(@as(u32, 20), range.end.character);
}

test "Location JSON parse" {
    const alloc = std.testing.allocator;
    const input = "{\"uri\":\"file:///test.zig\",\"range\":{\"start\":{\"line\":5,\"character\":10},\"end\":{\"line\":5,\"character\":20}}}";
    const parsed = try std.json.parseFromSlice(Location, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file:///test.zig", parsed.value.uri);
    try std.testing.expectEqual(@as(u32, 5), parsed.value.range.start.line);
    try std.testing.expectEqual(@as(u32, 10), parsed.value.range.start.character);
}

test "CompletionItem JSON parse" {
    const alloc = std.testing.allocator;
    const input = "{\"label\":\"println\",\"kind\":3,\"detail\":\"fn println(...) void\"}";
    const parsed = try std.json.parseFromSlice(CompletionItem, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("println", parsed.value.label);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.kind.?);
    try std.testing.expectEqualStrings("fn println(...) void", parsed.value.detail.?);
}

test "CompletionItem minimal JSON parse" {
    const alloc = std.testing.allocator;
    const input = "{\"label\":\"x\"}";
    const parsed = try std.json.parseFromSlice(CompletionItem, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("x", parsed.value.label);
    try std.testing.expect(parsed.value.kind == null);
    try std.testing.expect(parsed.value.detail == null);
}

test "Diagnostic JSON parse" {
    const alloc = std.testing.allocator;
    const input =
        \\{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"error here"}
    ;
    const parsed = try std.json.parseFromSlice(Diagnostic, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.severity.?);
    try std.testing.expectEqualStrings("error here", parsed.value.message);
}

test "DocumentSymbol with children JSON parse" {
    const alloc = std.testing.allocator;
    const input =
        \\{"name":"Foo","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"children":[{"name":"bar","kind":12,"range":{"start":{"line":1,"character":0},"end":{"line":3,"character":0}},"selectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}}]}
    ;
    const parsed = try std.json.parseFromSlice(DocumentSymbol, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Foo", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 23), parsed.value.kind);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.children.?.len);
    try std.testing.expectEqualStrings("bar", parsed.value.children.?[0].name);
}

test "completionKindName coverage" {
    try std.testing.expectEqualStrings("Text", completionKindName(1));
    try std.testing.expectEqualStrings("Function", completionKindName(3));
    try std.testing.expectEqualStrings("Struct", completionKindName(22));
    try std.testing.expectEqualStrings("Keyword", completionKindName(14));
    try std.testing.expectEqualStrings("Unknown", completionKindName(null));
    try std.testing.expectEqualStrings("Unknown", completionKindName(0));
    try std.testing.expectEqualStrings("Unknown", completionKindName(99));
}

/// Map completion item kind to string.
pub fn completionKindName(kind: ?u32) []const u8 {
    return switch (kind orelse 0) {
        1 => "Text",
        2 => "Method",
        3 => "Function",
        4 => "Constructor",
        5 => "Field",
        6 => "Variable",
        7 => "Class",
        8 => "Interface",
        9 => "Module",
        10 => "Property",
        11 => "Unit",
        12 => "Value",
        13 => "Enum",
        14 => "Keyword",
        15 => "Snippet",
        16 => "Color",
        17 => "File",
        18 => "Reference",
        19 => "Folder",
        20 => "EnumMember",
        21 => "Constant",
        22 => "Struct",
        23 => "Event",
        24 => "Operator",
        25 => "TypeParameter",
        else => "Unknown",
    };
}
