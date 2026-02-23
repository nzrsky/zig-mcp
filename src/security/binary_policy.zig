const std = @import("std");

pub fn isTrustedBinaryPath(path: []const u8, home: ?[]const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;

    const trusted_prefixes = [_][]const u8{
        "/usr/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/home/linuxbrew/.linuxbrew/bin",
    };
    for (trusted_prefixes) |prefix| {
        if (isWithinPrefix(prefix, path)) return true;
    }

    if (home) |h| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const home_bin = std.fmt.bufPrint(&buf, "{s}/bin", .{h}) catch return false;
        if (isWithinPrefix(home_bin, path)) return true;
    }

    return false;
}

fn isWithinPrefix(prefix: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

test "trusted binary path allows system bins" {
    try std.testing.expect(isTrustedBinaryPath("/usr/bin/zig", null));
    try std.testing.expect(isTrustedBinaryPath("/usr/local/bin/zls", null));
}

test "trusted binary path allows home bin" {
    try std.testing.expect(isTrustedBinaryPath("/home/alice/bin/zvm", "/home/alice"));
    try std.testing.expect(!isTrustedBinaryPath("/home/bob/bin/zvm", "/home/alice"));
}

test "trusted binary path rejects untrusted paths" {
    try std.testing.expect(!isTrustedBinaryPath("/tmp/zig", null));
    try std.testing.expect(!isTrustedBinaryPath("relative/zig", null));
    try std.testing.expect(!isTrustedBinaryPath("/usr/bin-evil/zig", null));
}
