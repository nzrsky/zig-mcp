const std = @import("std");
const json_rpc = @import("../types/json_rpc.zig");
const compat = @import("../compat.zig");

/// MCP transport: newline-delimited JSON-RPC over stdin/stdout.
/// Each message is a single JSON object followed by '\n'.
pub const McpTransport = struct {
    stdin_file: compat.File,
    stdout_file: compat.File,
    stdout_mutex: compat.Mutex = .{},

    pub fn init() McpTransport {
        return .{
            .stdin_file = compat.File.stdin(),
            .stdout_file = compat.File.stdout(),
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
                error.ConnectionResetByPeer => return null,
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

fn readPipeAll(file: compat.File, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.read(buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test "writeMessage appends newline" {
    const p = try compat.pipe();
    defer p.read_end.close();

    var transport = McpTransport{
        .stdin_file = p.read_end,
        .stdout_file = p.write_end,
    };

    try transport.writeMessage("{\"test\":1}");
    transport.stdout_file.close();

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(p.read_end, &buf);
    try std.testing.expectEqualStrings("{\"test\":1}\n", data);
}

test "writeMessage multiple messages are newline-delimited" {
    const p = try compat.pipe();
    defer p.read_end.close();

    var transport = McpTransport{
        .stdin_file = p.read_end,
        .stdout_file = p.write_end,
    };

    try transport.writeMessage("first");
    try transport.writeMessage("second");
    transport.stdout_file.close();

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(p.read_end, &buf);
    try std.testing.expectEqualStrings("first\nsecond\n", data);
}
