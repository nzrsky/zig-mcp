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
        while (true) {
            // Read line from stdin_file. We can't use a buffered reader here
            // because we need to hand back owned memory.
            var line: std.ArrayList(u8) = .empty;
            errdefer line.deinit(allocator);

            while (true) {
                var byte: [1]u8 = undefined;
                const n = self.stdin_file.read(&byte) catch |err| switch (err) {
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

            if (line.items.len == 0) continue; // ignore blank lines
            return try line.toOwnedSlice(allocator);
        }
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

test "readMessage ignores blank lines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("mcp_input.txt", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll("\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n");
    try file.seekTo(0);

    var transport = McpTransport.init();
    transport.stdin_file = file;

    const msg = (try transport.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"ping\"") != null);
}
