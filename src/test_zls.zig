// --- tests
//! A stand-in for the ZLS child process, shared by the LSP client tests and
//! the end-to-end tool tests.

const std = @import("std");
const LspClient = @import("lsp/client.zig").LspClient;
const LspTransport = @import("lsp/transport.zig").LspTransport;
const testing = @import("testing.zig");

/// A stand-in for ZLS: the client's pipes on one side, raw file handles the
/// test drives on the other. Lets the correlation logic be exercised without a
/// real language server.
pub const FakeZls = struct {
    client: LspClient,
    /// What the client wrote to "ZLS stdin".
    requests: LspTransport.Reader,
    /// Where a fake response is written; surfaces as the client's stdout.
    responses: std.Io.File,
    to_zls_write: std.Io.File,
    from_zls_read: std.Io.File,
    io: std.Io,
    connected: bool = true,

    /// Two-phase on purpose: `connect` spawns a thread that captures
    /// `&self.client`, so the client must already sit at its final address.
    /// Returning a connected client by value would hand that thread a pointer
    /// into a dead stack frame.
    pub fn init(alloc: std.mem.Allocator) !FakeZls {
        const io = testing.io();
        const to_zls = try testing.Pipe.open();
        const from_zls = try testing.Pipe.open();

        return .{
            .client = LspClient.init(alloc, io),
            .requests = LspTransport.Reader.init(to_zls.read_end, io),
            .responses = from_zls.write_end,
            .to_zls_write = to_zls.write_end,
            .from_zls_read = from_zls.read_end,
            .io = io,
        };
    }

    pub fn start(self: *FakeZls) !void {
        self.client.request_timeout = .fromMilliseconds(300);
        try self.client.connect(self.to_zls_write, self.from_zls_read, null);
    }

    /// Read one framed message the client sent us.
    pub fn nextRequest(self: *FakeZls, alloc: std.mem.Allocator) !?[]const u8 {
        return self.requests.readMessage(alloc);
    }

    pub fn reply(self: *FakeZls, msg: []const u8) !void {
        try LspTransport.writeMessage(self.responses, self.io, msg);
    }

    /// Simulate the ZLS process dying: its end of both pipes goes away.
    pub fn kill(self: *FakeZls) void {
        if (!self.connected) return;
        self.connected = false;
        self.responses.close(self.io);
        self.requests.file.close(self.io);
    }

    pub fn deinit(self: *FakeZls) void {
        self.kill();
        self.client.deinit();
    }
};

/// Answer the next request with `result` spliced into a result envelope.
pub fn respondToNext(fake: *FakeZls, alloc: std.mem.Allocator, result: []const u8) !void {
    const req = (try fake.nextRequest(alloc)).?;
    defer alloc.free(req);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, req, .{});
    defer parsed.deinit();
    const id = parsed.value.object.get("id").?.integer;

    const msg = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result });
    defer alloc.free(msg);
    try fake.reply(msg);
}

