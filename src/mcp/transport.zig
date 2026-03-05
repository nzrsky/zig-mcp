const std = @import("std");
const json_rpc = @import("../types/json_rpc.zig");

/// MCP transport: newline-delimited JSON-RPC over stdin/stdout.
/// Each message is a single JSON object followed by '\n'.
pub const McpTransport = struct {
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    stdout_mutex: std.Thread.Mutex = .{},

    pub fn init() McpTransport {
        return .{
            .stdin_file = std.fs.File.stdin(),
            .stdout_file = std.fs.File.stdout(),
        };
    }

    /// Read one newline-delimited JSON message from stdin.
    /// Returns owned slice allocated with `allocator`, or null on EOF.
    pub fn readMessage(self: *McpTransport, allocator: std.mem.Allocator) !?[]const u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);

        const stdin = self.stdin_file;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = stdin.read(&byte) catch |err| switch (err) {
                error.BrokenPipe => return null,
                else => return err,
            };
            if (n == 0) {
                // EOF
                if (line.items.len == 0) return null;
                break;
            }
            if (byte[0] == '\n') break;
            if (byte[0] == '\r') continue; // skip CR
            try line.append(allocator, byte[0]);
            if (line.items.len > 1024 * 1024) return error.MessageTooLarge;
        }

        if (line.items.len == 0) return null;
        return try line.toOwnedSlice(allocator);
    }

    /// Write a newline-delimited JSON message to stdout.
    /// Thread-safe: uses mutex to serialize writes.
    pub fn writeMessage(self: *McpTransport, data: []const u8) !void {
        self.stdout_mutex.lock();
        defer self.stdout_mutex.unlock();
        try self.stdout_file.writeAll(data);
        try self.stdout_file.writeAll("\n");
    }
};

// ── Tests ──

fn readPipeAll(file: std.fs.File, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.read(buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test "writeMessage appends newline" {
    const fds = try std.posix.pipe();
    const read_end: std.fs.File = .{ .handle = fds[0] };
    defer read_end.close();

    var transport = McpTransport{
        .stdin_file = read_end,
        .stdout_file = .{ .handle = fds[1] },
    };

    try transport.writeMessage("{\"test\":1}");
    transport.stdout_file.close();

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(read_end, &buf);
    try std.testing.expectEqualStrings("{\"test\":1}\n", data);
}

test "writeMessage multiple messages are newline-delimited" {
    const fds = try std.posix.pipe();
    const read_end: std.fs.File = .{ .handle = fds[0] };
    defer read_end.close();

    var transport = McpTransport{
        .stdin_file = read_end,
        .stdout_file = .{ .handle = fds[1] },
    };

    try transport.writeMessage("first");
    try transport.writeMessage("second");
    transport.stdout_file.close();

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(read_end, &buf);
    try std.testing.expectEqualStrings("first\nsecond\n", data);
}
