const std = @import("std");
const PosixMutex = @import("../sync.zig").PosixMutex;
const testing = @import("../testing.zig");

/// Largest MCP message we accept.
pub const max_message_bytes: usize = 1024 * 1024;

/// MCP transport: newline-delimited JSON-RPC over stdin/stdout.
/// Each message is a single JSON object followed by '\n'.
pub const McpTransport = struct {
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    io: std.Io,
    stdout_mutex: PosixMutex = .{},
    /// Read-ahead buffer. Messages routinely run to tens of kilobytes, and one
    /// syscall per byte is not a sane way to read them.
    buf: [8192]u8 = @splat(0),
    buf_start: usize = 0,
    buf_end: usize = 0,

    pub fn init(io: std.Io) McpTransport {
        return .{
            .stdin_file = std.Io.File.stdin(),
            .stdout_file = std.Io.File.stdout(),
            .io = io,
        };
    }

    /// Read a single byte from the buffer, refilling from stdin as needed.
    /// Returns null at end of stream.
    fn readByte(self: *McpTransport) !?u8 {
        if (self.buf_start >= self.buf_end) {
            const n = self.stdin_file.readStreaming(self.io, &.{&self.buf}) catch |err| switch (err) {
                error.EndOfStream, error.ConnectionResetByPeer => return null,
                else => return err,
            };
            if (n == 0) return null;
            self.buf_start = 0;
            self.buf_end = n;
        }
        const byte = self.buf[self.buf_start];
        self.buf_start += 1;
        return byte;
    }

    /// Read one newline-delimited JSON message from stdin.
    /// Returns owned slice allocated with `allocator`, or null on EOF.
    pub fn readMessage(self: *McpTransport, allocator: std.mem.Allocator) !?[]const u8 {
        var line: std.ArrayList(u8) = .empty;
        // Covers every exit below, including the EOF path that discards a
        // partial line.
        errdefer line.deinit(allocator);

        while (true) {
            const byte = (try self.readByte()) orelse {
                if (line.items.len == 0) return null;
                break; // EOF terminates the final unterminated line
            };
            if (byte == '\n') break;
            if (byte == '\r') continue; // tolerate CRLF
            try line.append(allocator, byte);
            if (line.items.len > max_message_bytes) return error.MessageTooLarge;
        }

        if (line.items.len == 0) {
            line.deinit(allocator);
            return null;
        }
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

/// A transport wired to two pipes: `input` feeds its stdin, `output` collects
/// what it writes.
const Loopback = struct {
    transport: McpTransport,
    input: std.Io.File,
    output: std.Io.File,
    stdin_read: std.Io.File,
    stdout_write: std.Io.File,
    output_closed: bool = false,

    fn init() !Loopback {
        const in = try testing.Pipe.open();
        const out = try testing.Pipe.open();
        return .{
            .transport = .{
                .stdin_file = in.read_end,
                .stdout_file = out.write_end,
                .io = testing.io(),
            },
            .input = in.write_end,
            .output = out.read_end,
            .stdin_read = in.read_end,
            .stdout_write = out.write_end,
        };
    }

    fn feed(self: *Loopback, data: []const u8) !void {
        try self.input.writeStreamingAll(testing.io(), data);
    }

    fn closeInput(self: *Loopback) void {
        self.input.close(testing.io());
    }

    fn collect(self: *Loopback, buf: []u8) ![]const u8 {
        if (!self.output_closed) {
            self.stdout_write.close(testing.io());
            self.output_closed = true;
        }
        return testing.readAll(self.output, buf);
    }

    fn deinit(self: *Loopback) void {
        const io = testing.io();
        if (!self.output_closed) self.stdout_write.close(io);
        self.output.close(io);
        self.stdin_read.close(io);
    }
};

test "writeMessage appends newline" {
    var lb = try Loopback.init();
    defer lb.deinit();
    lb.closeInput();

    try lb.transport.writeMessage("{\"test\":1}");

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"test\":1}\n", try lb.collect(&buf));
}

test "writeMessage multiple messages are newline-delimited" {
    var lb = try Loopback.init();
    defer lb.deinit();
    lb.closeInput();

    try lb.transport.writeMessage("first");
    try lb.transport.writeMessage("second");

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("first\nsecond\n", try lb.collect(&buf));
}

test "readMessage splits on newlines" {
    const alloc = std.testing.allocator;
    var lb = try Loopback.init();
    defer lb.deinit();

    try lb.feed("{\"a\":1}\n{\"b\":2}\n");
    lb.closeInput();

    const first = (try lb.transport.readMessage(alloc)).?;
    defer alloc.free(first);
    try std.testing.expectEqualStrings("{\"a\":1}", first);

    const second = (try lb.transport.readMessage(alloc)).?;
    defer alloc.free(second);
    try std.testing.expectEqualStrings("{\"b\":2}", second);

    try std.testing.expect(try lb.transport.readMessage(alloc) == null);
}

test "readMessage strips CR and skips blank lines" {
    const alloc = std.testing.allocator;
    var lb = try Loopback.init();
    defer lb.deinit();

    try lb.feed("{\"a\":1}\r\n");
    lb.closeInput();

    const msg = (try lb.transport.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("{\"a\":1}", msg);
}

test "readMessage returns the final unterminated line" {
    const alloc = std.testing.allocator;
    var lb = try Loopback.init();
    defer lb.deinit();

    try lb.feed("{\"a\":1}");
    lb.closeInput();

    const msg = (try lb.transport.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("{\"a\":1}", msg);
    try std.testing.expect(try lb.transport.readMessage(alloc) == null);
}

test "readMessage returns null on empty input" {
    const alloc = std.testing.allocator;
    var lb = try Loopback.init();
    defer lb.deinit();
    lb.closeInput();

    try std.testing.expect(try lb.transport.readMessage(alloc) == null);
}

test "readMessage survives a message larger than the read buffer" {
    const alloc = std.testing.allocator;
    var lb = try Loopback.init();
    defer lb.deinit();

    const big = try alloc.alloc(u8, 40_000);
    defer alloc.free(big);
    @memset(big, 'x');

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(l: *Loopback, payload: []const u8) !void {
            try l.feed(payload);
            try l.feed("\n");
            l.closeInput();
        }
    }.run, .{ &lb, big });
    defer writer.join();

    const msg = (try lb.transport.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expectEqual(@as(usize, 40_000), msg.len);
    try std.testing.expectEqualStrings(big, msg);
}

test "readMessage rejects a message past the size cap" {
    // Guards the `max_message_bytes` limit itself: without a test that crosses
    // it, the check is executed on every byte but never actually verified.
    const alloc = std.testing.allocator;
    var lb = try Loopback.init();
    defer lb.deinit();

    const oversized = try alloc.alloc(u8, max_message_bytes + 16);
    defer alloc.free(oversized);
    @memset(oversized, 'x');

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(l: *Loopback, payload: []const u8) void {
            // The reader bails out mid-stream, so this write is expected to
            // fail once the pipe backs up; that is the scenario under test.
            l.feed(payload) catch {};
            l.closeInput();
        }
    }.run, .{ &lb, oversized });
    defer writer.join();

    try std.testing.expectError(error.MessageTooLarge, lb.transport.readMessage(alloc));
}
