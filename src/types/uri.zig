const std = @import("std");

/// Convert a file system path to a file:// URI.
/// Caller owns the returned memory.
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // file:///absolute/path
    const prefix = "file://";
    var len: usize = prefix.len;

    // Count encoded length
    for (path) |c| {
        len += if (needsEncoding(c)) @as(usize, 3) else 1;
    }

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    for (path) |c| {
        if (needsEncoding(c)) {
            buf[pos] = '%';
            buf[pos + 1] = hexDigit(c >> 4);
            buf[pos + 2] = hexDigit(c & 0xf);
            pos += 3;
        } else {
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf;
}

/// Convert a file:// URI back to a file system path.
/// Caller owns the returned memory.
pub fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        return error.InvalidUri;
    }

    const encoded = uri[prefix.len..];
    // Count decoded length
    var len: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            len += 1;
            i += 3;
        } else {
            len += 1;
            i += 1;
        }
    }

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    var pos: usize = 0;
    i = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = unhex(encoded[i + 1]) orelse return error.InvalidUri;
            const lo = unhex(encoded[i + 2]) orelse return error.InvalidUri;
            buf[pos] = (@as(u8, hi) << 4) | @as(u8, lo);
            pos += 1;
            i += 3;
        } else {
            buf[pos] = encoded[i];
            pos += 1;
            i += 1;
        }
    }
    return buf[0..pos];
}

/// Make an absolute path from workspace root and relative path.
/// Caller owns returned memory.
pub fn resolvePath(allocator: std.mem.Allocator, workspace: []const u8, relative: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return allocator.dupe(u8, relative);
    }
    return std.fs.path.join(allocator, &.{ workspace, relative });
}

/// Resolve a path and enforce that it stays within the canonical workspace root.
/// Returns canonical absolute path on success.
pub fn resolvePathWithinWorkspace(allocator: std.mem.Allocator, workspace: []const u8, file_path: []const u8) ![]const u8 {
    const abs_path = try resolvePath(allocator, workspace, file_path);
    defer allocator.free(abs_path);

    const canonical_workspace = try std.fs.cwd().realpathAlloc(allocator, workspace);
    defer allocator.free(canonical_workspace);

    const canonical_path = try std.fs.cwd().realpathAlloc(allocator, abs_path);
    errdefer allocator.free(canonical_path);

    if (!isWithinRoot(canonical_workspace, canonical_path)) {
        return error.PathOutsideWorkspace;
    }

    return canonical_path;
}

fn isWithinRoot(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, "/")) return std.mem.startsWith(u8, path, "/");
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/';
}

fn needsEncoding(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => false,
        else => true,
    };
}

fn hexDigit(v: u8) u8 {
    return "0123456789ABCDEF"[v & 0xf];
}

fn unhex(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

test "path to uri round trip" {
    const allocator = std.testing.allocator;
    const path = "/home/user/project/src/main.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///home/user/project/src/main.zig", uri);

    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}

test "pathToUri encodes special characters" {
    const allocator = std.testing.allocator;
    const path = "/home/user/my file#1.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%20") != null);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%23") != null);
    try std.testing.expect(std.mem.startsWith(u8, uri, "file:///"));
}

test "uriToPath rejects non-file URIs" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "http://example.com"));
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "ftp://files/a.zig"));
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, ""));
}

test "uriToPath invalid percent encoding" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "file:///a%ZZb"));
    try std.testing.expectError(error.InvalidUri, uriToPath(allocator, "file:///a%GGb"));
}

test "pathToUri preserves allowed chars" {
    const allocator = std.testing.allocator;
    const path = "/usr/local/bin/zls-0.16.0";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///usr/local/bin/zls-0.16.0", uri);
}

test "round trip with all printable ASCII" {
    const allocator = std.testing.allocator;
    const path = "/test/hello world!@$&()+=[];,";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}

test "resolvePath absolute path returned as-is" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/workspace", "/absolute/path.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/absolute/path.zig", result);
}

test "resolvePath joins relative to workspace" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/workspace", "src/main.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", result);
}

test "resolvePathWithinWorkspace accepts path inside root" {
    const allocator = std.testing.allocator;
    const result = try resolvePathWithinWorkspace(allocator, "/tmp", "/tmp");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp", result);
}

test "resolvePathWithinWorkspace rejects absolute path outside root" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.PathOutsideWorkspace, resolvePathWithinWorkspace(allocator, "/tmp", "/etc/passwd"));
}

test "resolvePathWithinWorkspace rejects traversal outside root" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.PathOutsideWorkspace, resolvePathWithinWorkspace(allocator, "/tmp", "/tmp/../etc/passwd"));
}

test "uri with spaces" {
    const allocator = std.testing.allocator;
    const path = "/home/user/my project/file.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%20") != null);

    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}
