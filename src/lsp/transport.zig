const std = @import("std");

/// LSP transport: Content-Length framed JSON-RPC.
/// Format: `Content-Length: N\r\n\r\n<N bytes of JSON>`
pub const LspTransport = struct {
    /// Buffered reader for LSP stdout. Persists between readMessage calls
    /// so that bytes read-ahead during header parsing aren't lost.
    pub const Reader = struct {
        file: std.Io.File,
        io: std.Io,
        buf: [8192]u8 = undefined,
        buf_start: usize = 0,
        buf_end: usize = 0,

        pub fn init(file: std.Io.File, io: std.Io) Reader {
            return .{ .file = file, .io = io };
        }

        /// Read a single byte from the buffer (refills from file as needed).
        fn readByte(self: *Reader) !?u8 {
            if (self.buf_start >= self.buf_end) {
                const n = self.file.readStreaming(self.io, &.{&self.buf}) catch |err| switch (err) {
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

        /// Read exactly `dest.len` bytes, draining internal buffer first.
        fn readExact(self: *Reader, dest: []u8) !bool {
            var pos: usize = 0;
            while (pos < dest.len) {
                // Drain buffered bytes first
                const buffered = self.buf_end - self.buf_start;
                if (buffered > 0) {
                    const to_copy = @min(buffered, dest.len - pos);
                    @memcpy(dest[pos..][0..to_copy], self.buf[self.buf_start..][0..to_copy]);
                    self.buf_start += to_copy;
                    pos += to_copy;
                } else {
                    // Buffer empty — read directly into destination for large bodies
                    const n = self.file.readStreaming(self.io, &.{dest[pos..]}) catch |err| switch (err) {
                        error.EndOfStream, error.ConnectionResetByPeer => return false,
                        else => return err,
                    };
                    if (n == 0) return false; // EOF
                    pos += n;
                }
            }
            return true;
        }

        /// Read one LSP message. Returns owned slice, or null on EOF.
        pub fn readMessage(self: *Reader, allocator: std.mem.Allocator) !?[]const u8 {
            var content_length: ?usize = null;
            var header_buf: [4096]u8 = undefined;
            var header_pos: usize = 0;

            // Read headers byte by byte (from internal buffer — not 1 syscall/byte)
            while (true) {
                const byte = (try self.readByte()) orelse return null;

                if (header_pos >= header_buf.len) return error.HeaderTooLarge;
                header_buf[header_pos] = byte;
                header_pos += 1;

                // Check for \r\n\r\n end of headers
                if (header_pos >= 4 and
                    header_buf[header_pos - 4] == '\r' and
                    header_buf[header_pos - 3] == '\n' and
                    header_buf[header_pos - 2] == '\r' and
                    header_buf[header_pos - 1] == '\n')
                {
                    break;
                }
            }

            // Parse Content-Length from headers
            const headers = header_buf[0..header_pos];
            var line_iter = std.mem.splitSequence(u8, headers, "\r\n");
            while (line_iter.next()) |line| {
                if (line.len == 0) continue;
                const prefix = "Content-Length: ";
                if (std.mem.startsWith(u8, line, prefix)) {
                    content_length = std.fmt.parseInt(usize, line[prefix.len..], 10) catch continue;
                }
            }

            const len = content_length orelse return error.MissingContentLength;
            if (len == 0) return error.MissingContentLength;
            if (len > 10 * 1024 * 1024) return error.MessageTooLarge;

            // Read exact body (drains internal buffer first, then reads directly)
            const body = try allocator.alloc(u8, len);
            errdefer allocator.free(body);

            if (!try self.readExact(body)) {
                allocator.free(body);
                return null;
            }

            return body;
        }
    };

    /// Write one LSP message to the given file (ZLS stdin pipe).
    /// Adds Content-Length header framing.
    pub fn writeMessage(file: std.Io.File, io: std.Io, data: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        var header_w: std.Io.Writer = .fixed(&header_buf);
        try header_w.print("Content-Length: {d}\r\n\r\n", .{data.len});
        const header = header_w.buffered();

        try file.writeStreamingAll(io, header);
        try file.writeStreamingAll(io, data);
    }

    /// Legacy static readMessage for backward compat (no buffering).
    pub fn readMessage(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator) !?[]const u8 {
        var reader = Reader.init(file, io);
        return reader.readMessage(allocator);
    }
};

// ── Tests ──

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

fn testPipe() !struct { read_end: std.Io.File, write_end: std.Io.File } {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    return .{
        .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
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

test "writeMessage adds Content-Length framing" {
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "hello");
    p.write_end.close(io);

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(p.read_end, io, &buf);
    try std.testing.expectEqualStrings("Content-Length: 5\r\n\r\nhello", data);
}

test "writeMessage empty body" {
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "");
    p.write_end.close(io);

    var buf: [64]u8 = undefined;
    const data = try readPipeAll(p.read_end, io, &buf);
    try std.testing.expectEqualStrings("Content-Length: 0\r\n\r\n", data);
}

test "Reader parses single message" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "{\"ok\":true}");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    const msg = (try reader.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("{\"ok\":true}", msg);
}

test "Reader parses multiple sequential messages" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "msg1");
    try LspTransport.writeMessage(p.write_end, io, "msg2");
    try LspTransport.writeMessage(p.write_end, io, "msg3");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);

    const m1 = (try reader.readMessage(alloc)).?;
    defer alloc.free(m1);
    try std.testing.expectEqualStrings("msg1", m1);

    const m2 = (try reader.readMessage(alloc)).?;
    defer alloc.free(m2);
    try std.testing.expectEqualStrings("msg2", m2);

    const m3 = (try reader.readMessage(alloc)).?;
    defer alloc.free(m3);
    try std.testing.expectEqualStrings("msg3", m3);

    try std.testing.expect(try reader.readMessage(alloc) == null);
}

test "Reader returns null on empty pipe" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expect(try reader.readMessage(alloc) == null);
}

test "Reader returns error on missing Content-Length" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try p.write_end.writeStreamingAll(io, "Bad-Header: 5\r\n\r\nhello");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expectError(error.MissingContentLength, reader.readMessage(alloc));
}

test "Reader returns error on zero Content-Length" {
    const alloc = std.testing.allocator;
    const io = testIo();
    const p = try testPipe();
    defer p.read_end.close(io);

    try p.write_end.writeStreamingAll(io, "Content-Length: 0\r\n\r\n");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expectError(error.MissingContentLength, reader.readMessage(alloc));
}
