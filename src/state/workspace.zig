const std = @import("std");
const uri_util = @import("../types/uri.zig");

/// Workspace state: tracks root path and provides URI conversion.
pub const Workspace = struct {
    root_path: []const u8,
    root_uri: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8) !Workspace {
        // Resolve to absolute path
        const abs_path = if (std.fs.path.isAbsolute(workspace_path))
            try allocator.dupe(u8, workspace_path)
        else blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = try std.process.getCwd(&buf);
            break :blk try std.fs.path.join(allocator, &.{ cwd, workspace_path });
        };
        errdefer allocator.free(abs_path);

        const root_uri = try uri_util.pathToUri(allocator, abs_path);
        errdefer allocator.free(root_uri);

        return .{
            .root_path = abs_path,
            .root_uri = root_uri,
            .allocator = allocator,
        };
    }

    /// Convert a relative or absolute file path to a file:// URI.
    pub fn fileUri(self: *const Workspace, allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
        const abs = try uri_util.resolvePath(allocator, self.root_path, file_path);
        defer allocator.free(abs);
        return uri_util.pathToUri(allocator, abs);
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.root_path);
        self.allocator.free(self.root_uri);
    }
};

// ── Tests ──

test "Workspace init with absolute path" {
    const alloc = std.testing.allocator;
    var ws = try Workspace.init(alloc, "/tmp/test-project");
    defer ws.deinit();

    try std.testing.expectEqualStrings("/tmp/test-project", ws.root_path);
    try std.testing.expectEqualStrings("file:///tmp/test-project", ws.root_uri);
}

test "Workspace fileUri absolute path" {
    const alloc = std.testing.allocator;
    var ws = try Workspace.init(alloc, "/workspace");
    defer ws.deinit();

    const uri = try ws.fileUri(alloc, "/absolute/file.zig");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///absolute/file.zig", uri);
}

test "Workspace fileUri relative path" {
    const alloc = std.testing.allocator;
    var ws = try Workspace.init(alloc, "/workspace");
    defer ws.deinit();

    const uri = try ws.fileUri(alloc, "src/main.zig");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///workspace/src/main.zig", uri);
}

test "Workspace fileUri with special chars" {
    const alloc = std.testing.allocator;
    var ws = try Workspace.init(alloc, "/my workspace");
    defer ws.deinit();

    try std.testing.expect(std.mem.indexOf(u8, ws.root_uri, "%20") != null);
}
