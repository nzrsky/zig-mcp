//! Queries answered from the syntax tree, with no language server involved.
//!
//! These exist because a text search gets them *wrong*, not merely because it
//! is clumsy. Matching happens over tokens, so an occurrence inside a comment
//! or a string literal is invisible, and a form split across lines is found
//! just the same as a one-liner.

const std = @import("std");

/// Code shapes worth locating. Each is detectable from tokens alone, which is
/// what keeps comments and string literals out of the results.
pub const Shape = enum {
    /// `catch {}` — an error silently dropped on the floor.
    empty_catch,
    /// `catch unreachable` — an error turned into a panic.
    catch_unreachable,
    /// `x = undefined` — a value read before it is written is illegal behaviour.
    undefined_init,
    /// A bare `unreachable`.
    unreachable_literal,
    /// `@panic(...)`.
    panic,

    pub fn fromString(name: []const u8) ?Shape {
        return std.meta.stringToEnum(Shape, name);
    }

    pub fn describe(shape: Shape) []const u8 {
        return switch (shape) {
            .empty_catch => "error swallowed by an empty catch",
            .catch_unreachable => "error converted to a panic",
            .undefined_init => "initialized to undefined",
            .unreachable_literal => "unreachable",
            .panic => "@panic call",
        };
    }
};

pub const Match = struct {
    line: usize,
    column: usize,
    text: []const u8,
};

/// One parsed file plus the helpers both queries need.
const Parsed = struct {
    tree: std.zig.Ast,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, source: [:0]const u8) !Parsed {
        return .{
            .tree = try std.zig.Ast.parse(allocator, source, .{}),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Parsed) void {
        self.tree.deinit(self.allocator);
    }

    fn tokenCount(self: *const Parsed) usize {
        return self.tree.tokens.len;
    }

    fn tag(self: *const Parsed, index: usize) std.zig.Token.Tag {
        return self.tree.tokenTag(@intCast(index));
    }

    fn slice(self: *const Parsed, index: usize) []const u8 {
        return self.tree.tokenSlice(@intCast(index));
    }

    /// Source line holding `index`, trimmed.
    fn lineText(self: *const Parsed, index: usize) []const u8 {
        const loc = self.tree.tokenLocation(0, @intCast(index));
        return std.mem.trim(u8, self.tree.source[loc.line_start..loc.line_end], " \t\r");
    }

    fn position(self: *const Parsed, index: usize) struct { line: usize, column: usize } {
        const loc = self.tree.tokenLocation(0, @intCast(index));
        return .{ .line = loc.line + 1, .column = loc.column + 1 };
    }

    /// Index of the token after an optional `|payload|` capture.
    fn skipCapture(self: *const Parsed, after: usize) usize {
        var i = after;
        if (i < self.tokenCount() and self.tag(i) == .pipe) {
            i += 1;
            while (i < self.tokenCount() and self.tag(i) != .pipe) i += 1;
            i += 1; // closing pipe
        }
        return i;
    }
};

/// Locate every occurrence of `shape` in `source`.
pub fn findShape(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    shape: Shape,
    matches: *std.ArrayList(Match),
) !void {
    var parsed = try Parsed.init(allocator, source);
    defer parsed.deinit();

    var i: usize = 0;
    while (i < parsed.tokenCount()) : (i += 1) {
        const hit: ?usize = switch (shape) {
            .empty_catch, .catch_unreachable => blk: {
                if (parsed.tag(i) != .keyword_catch) break :blk null;
                const next = parsed.skipCapture(i + 1);
                if (next >= parsed.tokenCount()) break :blk null;
                switch (shape) {
                    // `{` immediately followed by `}` — whitespace and newlines
                    // are not tokens, so a multi-line empty block matches too.
                    .empty_catch => break :blk if (parsed.tag(next) == .l_brace and
                        next + 1 < parsed.tokenCount() and
                        parsed.tag(next + 1) == .r_brace) i else null,
                    .catch_unreachable => break :blk if (parsed.tag(next) == .keyword_unreachable) i else null,
                    else => unreachable,
                }
            },
            .undefined_init => blk: {
                if (parsed.tag(i) != .identifier) break :blk null;
                if (!std.mem.eql(u8, parsed.slice(i), "undefined")) break :blk null;
                // Only an assignment counts; `undefined` as a plain expression
                // (a default field value, say) is reported by its own site.
                if (i == 0 or parsed.tag(i - 1) != .equal) break :blk null;
                break :blk i;
            },
            .unreachable_literal => if (parsed.tag(i) == .keyword_unreachable) i else null,
            .panic => blk: {
                if (parsed.tag(i) != .builtin) break :blk null;
                break :blk if (std.mem.eql(u8, parsed.slice(i), "@panic")) i else null;
            },
        };

        const token = hit orelse continue;
        const pos = parsed.position(token);
        try matches.append(allocator, .{
            .line = pos.line,
            .column = pos.column,
            .text = try allocator.dupe(u8, parsed.lineText(token)),
        });
    }
}

pub const UnusedDecl = struct {
    name: []const u8,
    line: usize,
    column: usize,
    kind: []const u8,
};

/// Private declarations that nothing in the file refers to.
///
/// Sound by construction: a declaration without `pub` cannot be named from
/// another file, so the file itself is the whole search space. Neither the
/// compiler nor zlint's unused-decls reports these.
///
/// Conservative in one direction only: a struct-literal field or a member
/// access that happens to share the name counts as a use, so the answer may
/// omit an unused declaration but never invents one.
pub fn findUnusedPrivate(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    out: *std.ArrayList(UnusedDecl),
) !void {
    var parsed = try Parsed.init(allocator, source);
    defer parsed.deinit();

    for (parsed.tree.rootDecls()) |node| {
        const name_token: usize, const kind: []const u8 = switch (parsed.tree.nodeTag(node)) {
            .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => blk: {
                const decl = parsed.tree.fullVarDecl(node) orelse continue;
                if (decl.visib_token != null) continue; // pub: reachable elsewhere
                break :blk .{ @as(usize, decl.ast.mut_token) + 1, "declaration" };
            },
            .fn_decl, .fn_proto, .fn_proto_simple, .fn_proto_multi, .fn_proto_one => blk: {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                const proto = parsed.tree.fullFnProto(&buf, node) orelse continue;
                if (proto.visib_token != null) continue;
                const name = proto.name_token orelse continue;
                break :blk .{ @as(usize, name), "function" };
            },
            else => continue,
        };

        if (parsed.tag(name_token) != .identifier) continue;
        const name = parsed.slice(name_token);

        var used = false;
        var i: usize = 0;
        while (i < parsed.tokenCount()) : (i += 1) {
            if (i == name_token) continue;
            if (parsed.tag(i) != .identifier) continue;
            if (std.mem.eql(u8, parsed.slice(i), name)) {
                used = true;
                break;
            }
        }
        if (used) continue;

        const pos = parsed.position(name_token);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = pos.line,
            .column = pos.column,
            .kind = kind,
        });
    }
}

// ── Tests ──

fn shapeLines(alloc: std.mem.Allocator, src: [:0]const u8, shape: Shape) ![]const Match {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(alloc);
    try findShape(alloc, src, shape, &matches);
    return matches.toOwnedSlice(alloc);
}

fn freeMatches(alloc: std.mem.Allocator, matches: []const Match) void {
    for (matches) |m| alloc.free(m.text);
    alloc.free(matches);
}

test "empty catch is found across lines and never in comments or strings" {
    const alloc = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\// foo() catch {} in a comment
        \\const note = "bar() catch {}";
        \\fn a() void {
        \\    foo() catch {};
        \\    bar() catch {
        \\    };
        \\    baz() catch |err| {};
        \\    qux() catch {
        \\        log();
        \\    };
        \\}
    ;
    const matches = try shapeLines(alloc, src, .empty_catch);
    defer freeMatches(alloc, matches);

    // Lines 5, 6 and 8 match; the comment, the string and the non-empty block
    // do not. A text search would report five hits, three of them wrong.
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(@as(usize, 5), matches[0].line);
    try std.testing.expectEqual(@as(usize, 6), matches[1].line);
    try std.testing.expectEqual(@as(usize, 8), matches[2].line);
}

test "catch unreachable is distinct from an empty catch" {
    const alloc = std.testing.allocator;
    const src =
        \\fn a() void {
        \\    foo() catch unreachable;
        \\    bar() catch {};
        \\    baz() catch |e| unreachable;
        \\}
    ;
    const matches = try shapeLines(alloc, src, .catch_unreachable);
    defer freeMatches(alloc, matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 2), matches[0].line);
    try std.testing.expectEqual(@as(usize, 4), matches[1].line);
}

test "undefined counts only where it is assigned" {
    const alloc = std.testing.allocator;
    const src =
        \\const s = "undefined";
        \\// undefined in a comment
        \\fn a() void {
        \\    var x: u8 = undefined;
        \\    const y = undefined;
        \\}
        \\const S = struct { f: u8 = undefined };
    ;
    const matches = try shapeLines(alloc, src, .undefined_init);
    defer freeMatches(alloc, matches);
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(@as(usize, 4), matches[0].line);
    try std.testing.expectEqual(@as(usize, 5), matches[1].line);
    try std.testing.expectEqual(@as(usize, 7), matches[2].line);
}

test "unreachable and @panic" {
    const alloc = std.testing.allocator;
    const src =
        \\fn a() void {
        \\    if (x) unreachable;
        \\    @panic("boom");
        \\    // @panic("in a comment")
        \\}
    ;
    const u = try shapeLines(alloc, src, .unreachable_literal);
    defer freeMatches(alloc, u);
    try std.testing.expectEqual(@as(usize, 1), u.len);

    const p = try shapeLines(alloc, src, .panic);
    defer freeMatches(alloc, p);
    try std.testing.expectEqual(@as(usize, 1), p.len);
    try std.testing.expectEqual(@as(usize, 3), p[0].line);
}

test "shape query on a file with syntax errors still parses what it can" {
    const alloc = std.testing.allocator;
    const src =
        \\fn a() void {
        \\    foo() catch {};
        \\    this is not valid zig @@@
        \\}
    ;
    const matches = try shapeLines(alloc, src, .empty_catch);
    defer freeMatches(alloc, matches);
    try std.testing.expect(matches.len >= 1);
}

fn unusedIn(alloc: std.mem.Allocator, src: [:0]const u8) ![]const UnusedDecl {
    var out: std.ArrayList(UnusedDecl) = .empty;
    errdefer out.deinit(alloc);
    try findUnusedPrivate(alloc, src, &out);
    return out.toOwnedSlice(alloc);
}

fn freeUnused(alloc: std.mem.Allocator, items: []const UnusedDecl) void {
    for (items) |d| alloc.free(d.name);
    alloc.free(items);
}

test "unused private declarations are reported, pub ones are not" {
    const alloc = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\
        \\fn helperUsed() void {}
        \\fn helperDead() void {}
        \\pub fn exported() void {}
        \\const dead_const = 1;
        \\const live_const = 2;
        \\
        \\pub fn entry() void {
        \\    helperUsed();
        \\    _ = live_const;
        \\}
    ;
    const items = try unusedIn(alloc, src);
    defer freeUnused(alloc, items);

    // `std` counts too: it is imported and then never named again.
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("std", items[0].name);
    try std.testing.expectEqualStrings("helperDead", items[1].name);
    try std.testing.expectEqualStrings("dead_const", items[2].name);
}

test "a declaration used only from a test still counts as used" {
    const alloc = std.testing.allocator;
    const src =
        \\fn onlyTested() void {}
        \\
        \\test "x" {
        \\    onlyTested();
        \\}
    ;
    const items = try unusedIn(alloc, src);
    defer freeUnused(alloc, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "a name mentioned only in a comment does not count as a use" {
    const alloc = std.testing.allocator;
    const src =
        \\// deadFn is described here but never called
        \\const s = "deadFn()";
        \\fn deadFn() void {}
    ;
    const items = try unusedIn(alloc, src);
    defer freeUnused(alloc, items);
    // `s` is unused as well; what matters is that the comment and the string
    // literal did not save `deadFn`.
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("s", items[0].name);
    try std.testing.expectEqualStrings("deadFn", items[1].name);
}

test "std import is reported when nothing uses it" {
    const alloc = std.testing.allocator;
    const items = try unusedIn(alloc, "const std = @import(\"std\");\n");
    defer freeUnused(alloc, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("std", items[0].name);
}

test "Shape.fromString rejects unknown names" {
    try std.testing.expectEqual(Shape.empty_catch, Shape.fromString("empty_catch").?);
    try std.testing.expect(Shape.fromString("nonsense") == null);
}
