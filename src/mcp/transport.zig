const std = @import("std");
const json_rpc = @import("../types/json_rpc.zig");
const PosixMutex = @import("../sync.zig").PosixMutex;

/// MCP transport: newline-delimited JSON-RPC over stdin/stdout.
/// Each message is a single JSON object followed by '\n'.
pub const McpTransport = struct {
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    io: std.Io,
    stdout_mutex: PosixMutex = .{},

    pub fn init(io: std.Io) McpTransport {
        return .{
            .stdin_file = std.Io.File.stdin(),
            .stdout_file = std.Io.File.stdout(),
            .io = io,
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
            const n = stdin.readStreaming(self.io, &.{&byte}) catch |err| switch (err) {
                error.EndOfStream => return if (line.items.len == 0) null else break,
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
        try self.stdout_file.writeStreamingAll(self.io, data);
        try self.stdout_file.writeStreamingAll(self.io, "\n");
    }
};

// ── Tests ──

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

fn readPipeAll(file: std.Io.File, io: std.Io, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(io, &.{buf[total..]}) catch return buf[0..total];
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test "writeMessage appends newline" {
    const io = testIo();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer read_end.close(io);

    var transport = McpTransport{
        .stdin_file = read_end,
        .stdout_file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        .io = io,
    };

    try transport.writeMessage("{\"test\":1}");
    transport.stdout_file.close(io);

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(read_end, io, &buf);
    try std.testing.expectEqualStrings("{\"test\":1}\n", data);
}

test "writeMessage multiple messages are newline-delimited" {
    const io = testIo();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer read_end.close(io);

    var transport = McpTransport{
        .stdin_file = read_end,
        .stdout_file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        .io = io,
    };

    try transport.writeMessage("first");
    try transport.writeMessage("second");
    transport.stdout_file.close(io);

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(read_end, io, &buf);
    try std.testing.expectEqualStrings("first\nsecond\n", data);
}
