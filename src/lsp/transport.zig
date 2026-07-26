const std = @import("std");
const testing = @import("../testing.zig");

/// Largest LSP body we are willing to buffer.
pub const max_message_bytes: usize = 10 * 1024 * 1024;

/// Errors produced while decoding the `Content-Length` framing.
pub const FramingError = error{
    /// Headers exceeded the fixed header buffer without a terminator.
    HeaderTooLarge,
    /// No parseable `Content-Length` header was present.
    MissingContentLength,
    /// `Content-Length: 0` — there is no such thing as an empty JSON-RPC body.
    EmptyMessage,
    /// `Content-Length` exceeds `max_message_bytes`.
    MessageTooLarge,
    /// The stream ended part-way through a header or body.
    UnexpectedEndOfMessage,
};

/// LSP transport: Content-Length framed JSON-RPC.
/// Format: `Content-Length: N\r\n\r\n<N bytes of JSON>`
pub const LspTransport = struct {
    /// Buffered reader for LSP stdout. Must persist between `readMessage`
    /// calls: header parsing reads ahead, and those bytes belong to the body
    /// (or the next message).
    pub const Reader = struct {
        file: std.Io.File,
        io: std.Io,
        buf: [8192]u8,
        buf_start: usize,
        buf_end: usize,

        pub fn init(file: std.Io.File, io: std.Io) Reader {
            return .{
                .file = file,
                .io = io,
                // SAFETY: buf_start == buf_end marks the buffer empty, so no
                // byte is ever read before readByte fills it.
                .buf = undefined,
                .buf_start = 0,
                .buf_end = 0,
            };
        }

        /// Read a single byte from the buffer (refills from the file as
        /// needed). Returns null at end of stream.
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

        /// Read exactly `dest.len` bytes, draining the internal buffer first.
        /// Returns false if the stream ended early.
        fn readExact(self: *Reader, dest: []u8) !bool {
            var pos: usize = 0;
            while (pos < dest.len) {
                const buffered = self.buf_end - self.buf_start;
                if (buffered > 0) {
                    const to_copy = @min(buffered, dest.len - pos);
                    @memcpy(dest[pos..][0..to_copy], self.buf[self.buf_start..][0..to_copy]);
                    self.buf_start += to_copy;
                    pos += to_copy;
                } else {
                    // Buffer empty — read straight into the destination so
                    // large bodies don't round-trip through `buf`.
                    const n = self.file.readStreaming(self.io, &.{dest[pos..]}) catch |err| switch (err) {
                        error.EndOfStream, error.ConnectionResetByPeer => return false,
                        else => return err,
                    };
                    if (n == 0) return false;
                    pos += n;
                }
            }
            return true;
        }

        /// Read one LSP message. Returns an owned slice of exactly
        /// `Content-Length` bytes, null on a clean end of stream (no bytes of a
        /// message seen), or an error. Never returns more bytes than the header
        /// declared.
        pub fn readMessage(self: *Reader, allocator: std.mem.Allocator) !?[]const u8 {
            var header_buf: [4096]u8 = undefined;
            var header_pos: usize = 0;

            // Headers, byte at a time out of the internal buffer.
            while (true) {
                const byte = (try self.readByte()) orelse {
                    if (header_pos == 0) return null; // clean EOF at a message boundary
                    return error.UnexpectedEndOfMessage;
                };

                if (header_pos >= header_buf.len) return error.HeaderTooLarge;
                header_buf[header_pos] = byte;
                header_pos += 1;

                if (header_pos >= 4 and
                    header_buf[header_pos - 4] == '\r' and
                    header_buf[header_pos - 3] == '\n' and
                    header_buf[header_pos - 2] == '\r' and
                    header_buf[header_pos - 1] == '\n')
                {
                    break;
                }
            }

            const len = try parseContentLength(header_buf[0..header_pos]);

            const body = try allocator.alloc(u8, len);
            errdefer allocator.free(body);

            if (!try self.readExact(body)) return error.UnexpectedEndOfMessage;
            return body;
        }
    };

    /// Parse `Content-Length` out of a raw header block. Header names are
    /// case-insensitive and the value may carry surrounding whitespace.
    fn parseContentLength(headers: []const u8) FramingError!usize {
        const name = "content-length";
        var content_length: ?usize = null;

        var line_iter = std.mem.splitSequence(u8, headers, "\r\n");
        while (line_iter.next()) |line| {
            if (line.len <= name.len or line[name.len] != ':') continue;
            var matches = true;
            for (line[0..name.len], name) |actual, expected| {
                if (std.ascii.toLower(actual) != expected) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;

            const value = std.mem.trim(u8, line[name.len + 1 ..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch continue;
        }

        const len = content_length orelse return error.MissingContentLength;
        if (len == 0) return error.EmptyMessage;
        if (len > max_message_bytes) return error.MessageTooLarge;
        return len;
    }

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
};

// ── Tests ──

/// Feed `raw` through a pipe and decode one message from it.
fn decodeOne(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const io = testing.io();
    const p = try testing.Pipe.open();
    defer p.read_end.close(io);

    try p.write_end.writeStreamingAll(io, raw);
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    return reader.readMessage(allocator);
}

test "writeMessage adds Content-Length framing" {
    const io = testing.io();
    const p = try testing.Pipe.open();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "hello");
    p.write_end.close(io);

    var buf: [64]u8 = undefined;
    const data = try testing.readAll(p.read_end, &buf);
    try std.testing.expectEqualStrings("Content-Length: 5\r\n\r\nhello", data);
}

test "writeMessage empty body" {
    const io = testing.io();
    const p = try testing.Pipe.open();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "");
    p.write_end.close(io);

    var buf: [64]u8 = undefined;
    const data = try testing.readAll(p.read_end, &buf);
    try std.testing.expectEqualStrings("Content-Length: 0\r\n\r\n", data);
}

test "Reader parses single message" {
    const alloc = std.testing.allocator;
    const msg = (try decodeOne(alloc, "Content-Length: 11\r\n\r\n{\"ok\":true}")).?;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("{\"ok\":true}", msg);
}

test "Reader parses multiple sequential messages" {
    const alloc = std.testing.allocator;
    const io = testing.io();
    const p = try testing.Pipe.open();
    defer p.read_end.close(io);

    try LspTransport.writeMessage(p.write_end, io, "msg1");
    try LspTransport.writeMessage(p.write_end, io, "msg2");
    try LspTransport.writeMessage(p.write_end, io, "msg3");
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);

    for ([_][]const u8{ "msg1", "msg2", "msg3" }) |expected| {
        const m = (try reader.readMessage(alloc)).?;
        defer alloc.free(m);
        try std.testing.expectEqualStrings(expected, m);
    }
    try std.testing.expect(try reader.readMessage(alloc) == null);
}

test "Reader returns null on empty pipe" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try decodeOne(alloc, "") == null);
}

test "Reader rejects missing Content-Length" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingContentLength, decodeOne(alloc, "Bad-Header: 5\r\n\r\nhello"));
}

test "Reader rejects zero Content-Length" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyMessage, decodeOne(alloc, "Content-Length: 0\r\n\r\n"));
}

test "Reader rejects negative Content-Length" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingContentLength, decodeOne(alloc, "Content-Length: -1\r\n\r\nhello"));
}

test "Reader rejects Content-Length above the cap" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MessageTooLarge, decodeOne(alloc, "Content-Length: 10485761\r\n\r\n"));
}

test "Reader accepts case-insensitive header name and padded value" {
    const alloc = std.testing.allocator;
    const msg = (try decodeOne(alloc, "content-LENGTH:  \t5  \r\nContent-Type: application/vscode-jsonrpc\r\n\r\nhello")).?;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("hello", msg);
}

test "Reader rejects body shorter than Content-Length" {
    // The `Content-Length` header over-declares: the decoder must fail rather
    // than hand back a short buffer.
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedEndOfMessage, decodeOne(alloc, "Content-Length: 64\r\n\r\ntoo short"));
}

test "Reader returns exactly Content-Length bytes when the body is longer" {
    const alloc = std.testing.allocator;
    const msg = (try decodeOne(alloc, "Content-Length: 5\r\n\r\nhelloTRAILING GARBAGE")).?;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("hello", msg);
    try std.testing.expectEqual(@as(usize, 5), msg.len);
}

test "Reader rejects truncated headers" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedEndOfMessage, decodeOne(alloc, "Content-Length: 5\r\n"));
}

test "Reader rejects bare-LF framing" {
    // Only CRLF terminates headers; an LF-only stream runs to EOF.
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedEndOfMessage, decodeOne(alloc, "Content-Length: 5\n\nhello"));
}

test "Reader rejects oversized headers" {
    const alloc = std.testing.allocator;
    const io = testing.io();
    const p = try testing.Pipe.open();
    defer p.read_end.close(io);

    var filler: [5000]u8 = undefined;
    @memset(&filler, 'x');
    try p.write_end.writeStreamingAll(io, "X-Pad: ");
    try p.write_end.writeStreamingAll(io, &filler);
    p.write_end.close(io);

    var reader = LspTransport.Reader.init(p.read_end, io);
    try std.testing.expectError(error.HeaderTooLarge, reader.readMessage(alloc));
}

test "round trip: writeMessage output decodes to the same body" {
    const alloc = std.testing.allocator;
    const io = testing.io();
    const bodies = [_][]const u8{ "{}", "a", "{\"deeply\":{\"nested\":[1,2,3]}}", "\x00\x01\xff binary" };

    for (bodies) |body| {
        const p = try testing.Pipe.open();
        defer p.read_end.close(io);
        try LspTransport.writeMessage(p.write_end, io, body);
        p.write_end.close(io);

        var reader = LspTransport.Reader.init(p.read_end, io);
        const decoded = (try reader.readMessage(alloc)).?;
        defer alloc.free(decoded);
        try std.testing.expectEqualStrings(body, decoded);
    }
}

test "parseContentLength is deterministic" {
    const headers = "Content-Length: 42\r\n\r\n";
    const first = try LspTransport.parseContentLength(headers);
    const second = try LspTransport.parseContentLength(headers);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 42), first);
}

/// Framing property: for any generated header/body pair the decoder either
/// fails or returns exactly `Content-Length` bytes — never more, never a short
/// buffer silently.
fn fuzzFraming(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;

    const declared: usize = smith.valueRangeAtMostWithHash(u8, 0, 64, 0x11);
    const actual: usize = smith.valueRangeAtMostWithHash(u8, 0, 64, 0x22);
    const pad: usize = smith.valueRangeAtMostWithHash(u8, 0, 3, 0x33);
    const crlf = smith.boolWeightedWithHash(1, 3, 0x44);

    var body: [64]u8 = undefined;
    smith.bytesWithHash(body[0..actual], 0x55);

    var len_buf: [32]u8 = undefined;
    const len_text = try std.fmt.bufPrint(&len_buf, "{d}", .{declared});

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, "Content-Length:");
    for (0..pad) |_| try raw.append(alloc, ' ');
    try raw.appendSlice(alloc, len_text);
    try raw.appendSlice(alloc, if (crlf) "\r\n\r\n" else "\n\n");
    try raw.appendSlice(alloc, body[0..actual]);

    const decoded = decodeOne(alloc, raw.items) catch return;
    const msg = decoded orelse return;
    defer alloc.free(msg);
    try std.testing.expectEqual(declared, msg.len);
    try std.testing.expect(declared <= actual);
    try std.testing.expectEqualStrings(body[0..declared], msg);
}

test "fuzz framing never over-reads" {
    try std.testing.fuzz({}, fuzzFraming, .{ .corpus = &.{
        "Content-Length: 5\r\n\r\nhello",
        "Content-Length: 64\r\n\r\nshort",
        "Content-Length: 0\r\n\r\n",
        "Content-Length:\r\n\r\n",
    } });
}
