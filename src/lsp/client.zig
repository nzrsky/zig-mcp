const std = @import("std");
const LspTransport = @import("transport.zig").LspTransport;
const json_rpc = @import("../types/json_rpc.zig");
const PosixMutex = @import("../sync.zig").PosixMutex;
const testing = @import("../testing.zig");
const FakeZls = @import("../test_zls.zig").FakeZls;
const respondToNext = @import("../test_zls.zig").respondToNext;

/// Pending request waiting for a response from ZLS.
///
/// Ownership: created by `sendRawRequest`, handed to `pending`, and only ever
/// retrieved again through `takePending`. Both the reader thread and the
/// requesting thread touch the payload exclusively under `pending_mutex`, so a
/// request that times out can never be destroyed while the reader is mid-write.
const PendingRequest = struct {
    response: ?[]const u8 = null,
    event: std.Io.Event = .unset,
};

/// LSP Client: manages request/response correlation with the ZLS child process.
///
/// Architecture:
/// - Main thread calls sendRequest() which blocks until reader thread delivers the response.
/// - Reader thread runs readerLoop() reading ZLS stdout and dispatching responses/notifications.
/// - Reader thread also answers server-initiated requests, so writes to ZLS
///   stdin are serialized through `write_mutex`.
pub const LspClient = struct {
    zls_stdin: ?std.Io.File,
    zls_stdout: ?std.Io.File,
    next_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    pending: std.AutoHashMapUnmanaged(i64, *PendingRequest),
    pending_mutex: PosixMutex = .{},
    write_mutex: PosixMutex = .{},
    reader_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stderr_thread: ?std.Thread = null,
    zls_stderr: ?std.Io.File = null,
    /// How long `sendRequest` waits before giving up. Overridable for tests.
    request_timeout: std.Io.Duration = .fromSeconds(30),
    /// Latest `textDocument/publishDiagnostics` payload per document URI,
    /// stored as the raw JSON text of the `diagnostics` array.
    diagnostics: std.StringHashMapUnmanaged([]const u8),
    diagnostics_mutex: PosixMutex = .{},

    const clock: std.Io.Clock = .awake;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) LspClient {
        return .{
            .zls_stdin = null,
            .zls_stdout = null,
            .pending = .empty,
            .diagnostics = .empty,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Connect to ZLS pipes and start reader thread.
    pub fn connect(self: *LspClient, stdin: std.Io.File, stdout: std.Io.File, stderr: ?std.Io.File) !void {
        self.zls_stdin = stdin;
        self.zls_stdout = stdout;
        self.zls_stderr = stderr;
        self.running.store(true, .release);

        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});

        if (stderr) |_| {
            self.stderr_thread = try std.Thread.spawn(.{}, stderrLoop, .{self});
        }
    }

    pub fn isConnected(self: *const LspClient) bool {
        return self.running.load(.acquire) and self.zls_stdin != null;
    }

    /// Send an LSP request and block until the response arrives.
    /// Returns owned response JSON body, or error on timeout/failure.
    pub fn sendRequest(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype) ![]const u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const msg = try json_rpc.writeRequest(allocator, .{ .integer = id }, method, params);
        defer allocator.free(msg);
        return self.sendRawRequest(allocator, id, msg);
    }

    /// Send an LSP notification (no response expected).
    pub fn sendNotification(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype) !void {
        const stdin = self.zls_stdin orelse return error.NotConnected;
        const msg = try json_rpc.writeNotification(allocator, method, params);
        defer allocator.free(msg);
        try self.writeRaw(stdin, msg);
    }

    /// Send a notification with empty params object (avoids [] vs {} serialization issue).
    pub fn sendRawNotification(self: *LspClient, allocator: std.mem.Allocator, method: []const u8) !void {
        const stdin = self.zls_stdin orelse return error.NotConnected;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
        , .{method});
        try self.writeRaw(stdin, aw.written());
    }

    /// Send LSP initialize request and initialized notification.
    pub fn initialize(self: *LspClient, allocator: std.mem.Allocator, workspace_uri: []const u8) ![]const u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);

        // Build the full request with raw JSON params for precise control
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"processId":null,"rootUri":"
        , .{id});
        try writeJsonStringBody(&aw.writer, workspace_uri);
        try aw.writer.writeAll(
            \\","capabilities":{"textDocument":{"hover":{"contentFormat":["markdown","plaintext"]},"completion":{"completionItem":{"snippetSupport":false}},"signatureHelp":{"signatureInformation":{"documentationFormat":["markdown","plaintext"]}},"publishDiagnostics":{"relatedInformation":true}}}}}}
        );

        const response = try self.sendRawRequest(allocator, id, aw.written());

        // Send initialized notification (must send empty object {}, not [])
        errdefer allocator.free(response);
        try self.sendRawNotification(allocator, "initialized");

        return response;
    }

    /// Escape `text` into a JSON string body (without the surrounding quotes).
    fn writeJsonStringBody(w: *std.Io.Writer, text: []const u8) !void {
        for (text) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                0x00...0x1f => try w.print("\\u{x:0>4}", .{c}),
                else => try w.writeByte(c),
            }
        }
    }

    /// Serialized write to the ZLS stdin pipe. The reader thread answers
    /// server-initiated requests, so this can be called from two threads.
    fn writeRaw(self: *LspClient, file: std.Io.File, msg: []const u8) !void {
        if (!self.running.load(.acquire)) return error.NotConnected;

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        LspTransport.writeMessage(file, self.io, msg) catch |err| {
            // A failed write to the child's stdin means the session is over
            // (broken pipe, closed handle). Report it as such so callers take
            // the reconnect path instead of guessing at an I/O error.
            log("write to ZLS failed: {s}", .{@errorName(err)});
            self.running.store(false, .release);
            self.signalAllPending();
            return error.NotConnected;
        };
    }

    /// Remove a pending request from the table. Runs under the same lock the
    /// reader holds while filling it in, so the returned pointer is not visible
    /// to any other thread and can be destroyed safely.
    fn takePending(self: *LspClient, id: i64) ?*PendingRequest {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const entry = self.pending.fetchRemove(id) orelse return null;
        return entry.value;
    }

    fn destroyPending(self: *LspClient, p: *PendingRequest) void {
        if (p.response) |r| self.allocator.free(r);
        self.allocator.destroy(p);
    }

    /// Send a pre-serialized LSP request message and wait for the response.
    fn sendRawRequest(self: *LspClient, allocator: std.mem.Allocator, id: i64, msg: []const u8) ![]const u8 {
        if (!self.running.load(.acquire)) return error.NotConnected;
        const stdin = self.zls_stdin orelse return error.NotConnected;

        const pending = try self.allocator.create(PendingRequest);
        pending.* = .{};
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            self.pending.put(self.allocator, id, pending) catch |err| {
                self.allocator.destroy(pending);
                return err;
            };
        }

        self.writeRaw(stdin, msg) catch |err| {
            if (self.takePending(id)) |p| self.destroyPending(p);
            return err;
        };

        const deadline_ts = clock.now(self.io).addDuration(self.request_timeout);
        const deadline: std.Io.Timeout = .{ .deadline = deadline_ts.withClock(clock) };
        var timed_out = false;

        while (!pending.event.isSet()) {
            pending.event.waitTimeout(self.io, deadline) catch |err| switch (err) {
                // `waitTimeout` also reports `Timeout` for spurious wakeups, so
                // the deadline is re-checked against the clock rather than
                // trusted outright.
                error.Timeout => {
                    if (pending.event.isSet()) break;
                    if (clock.now(self.io).nanoseconds >= deadline_ts.nanoseconds) {
                        timed_out = true;
                        break;
                    }
                },
                else => {
                    timed_out = true;
                    break;
                },
            };
        }

        // The reader may have delivered a response between the deadline
        // expiring and this removal — take it rather than leak it.
        const p = self.takePending(id) orelse return error.NoResponse;
        defer self.destroyPending(p);

        const response = p.response orelse
            return if (timed_out) error.RequestTimeout else error.NoResponse;
        return try allocator.dupe(u8, response);
    }

    /// Background thread: reads LSP messages from ZLS stdout, dispatches responses.
    fn readerLoop(self: *LspClient) void {
        defer {
            // Whatever ends this loop, no further response will ever arrive:
            // fail fast instead of making every later request wait out its
            // full timeout.
            self.running.store(false, .release);
            self.signalAllPending();
        }

        const stdout = self.zls_stdout orelse return;
        var reader = LspTransport.Reader.init(stdout, self.io);

        while (self.running.load(.acquire)) {
            const maybe_msg = reader.readMessage(self.allocator) catch |err| {
                log("LSP reader error: {s}", .{@errorName(err)});
                return;
            };
            const data = maybe_msg orelse {
                log("ZLS stdout closed", .{});
                return;
            };
            defer self.allocator.free(data);
            self.dispatch(data);
        }
    }

    /// Route one decoded LSP message.
    fn dispatch(self: *LspClient, data: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            log("Failed to parse LSP message", .{});
            return;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        const method: ?[]const u8 = if (obj.get("method")) |m| switch (m) {
            .string => |s| s,
            else => null,
        } else null;

        if (obj.get("id")) |id_val| {
            // `id` *and* `method` means ZLS is calling us, not answering us.
            // Its ids are numbered independently of ours, so treating this as a
            // response would corrupt an unrelated in-flight request.
            if (method) |m| {
                self.rejectServerRequest(id_val, m);
                return;
            }
            self.deliverResponse(id_val, data);
            return;
        }

        if (method) |m| self.handleNotification(m, obj);
    }

    fn deliverResponse(self: *LspClient, id_val: std.json.Value, data: []const u8) void {
        const id: i64 = switch (id_val) {
            .integer => |i| i,
            else => return, // we only ever send integer ids
        };

        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const p = self.pending.get(id) orelse return; // unknown or already-timed-out id

        if (p.response != null) return; // duplicate response for one id
        p.response = self.allocator.dupe(u8, data) catch null;
        // Still under the lock: a waiter that wakes here cannot destroy `p`
        // until this call returns and the lock is released.
        p.event.set(self.io);
    }

    /// Answer a server-initiated request so ZLS is not left waiting forever.
    fn rejectServerRequest(self: *LspClient, id_val: std.json.Value, method: []const u8) void {
        const stdin = self.zls_stdin orelse return;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        blk: {
            jw.beginObject() catch break :blk;
            jw.objectField("jsonrpc") catch break :blk;
            jw.write("2.0") catch break :blk;
            jw.objectField("id") catch break :blk;
            jw.write(id_val) catch break :blk;
            jw.objectField("error") catch break :blk;
            jw.beginObject() catch break :blk;
            jw.objectField("code") catch break :blk;
            jw.write(json_rpc.ErrorCode.method_not_found) catch break :blk;
            jw.objectField("message") catch break :blk;
            jw.write("zig-mcp does not implement server-initiated requests") catch break :blk;
            jw.endObject() catch break :blk;
            jw.endObject() catch break :blk;

            self.writeRaw(stdin, aw.written()) catch break :blk;
            return;
        }
        log("failed to reject server request {s}", .{method});
    }

    fn handleNotification(self: *LspClient, method: []const u8, obj: std.json.ObjectMap) void {
        if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) return;

        const params = switch (obj.get("params") orelse return) {
            .object => |o| o,
            else => return,
        };
        const uri = switch (params.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };
        const items = params.get("diagnostics") orelse return;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        jw.write(items) catch return;

        const stored = self.allocator.dupe(u8, aw.written()) catch return;
        const key = self.allocator.dupe(u8, uri) catch {
            self.allocator.free(stored);
            return;
        };

        self.diagnostics_mutex.lock();
        defer self.diagnostics_mutex.unlock();

        if (self.diagnostics.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        self.diagnostics.put(self.allocator, key, stored) catch {
            self.allocator.free(key);
            self.allocator.free(stored);
        };
    }

    /// Drop any cached diagnostics for `uri` (called when the document changes,
    /// so a stale report is never mistaken for a fresh one).
    pub fn clearDiagnostics(self: *LspClient, uri: []const u8) void {
        self.diagnostics_mutex.lock();
        defer self.diagnostics_mutex.unlock();
        if (self.diagnostics.fetchRemove(uri)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    /// Copy of the cached diagnostics array for `uri`, if any.
    pub fn getDiagnostics(self: *LspClient, allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
        self.diagnostics_mutex.lock();
        defer self.diagnostics_mutex.unlock();
        const found = self.diagnostics.get(uri) orelse return null;
        return try allocator.dupe(u8, found);
    }

    /// Wait up to `timeout_ms` for diagnostics to arrive for `uri`.
    /// Diagnostics are pushed by ZLS, so there is nothing to request — this
    /// polls the cache the reader thread fills.
    pub fn waitForDiagnostics(
        self: *LspClient,
        allocator: std.mem.Allocator,
        uri: []const u8,
        timeout_ms: u32,
    ) !?[]const u8 {
        const step_ms = 25;
        var waited: u32 = 0;
        while (true) {
            if (try self.getDiagnostics(allocator, uri)) |d| return d;
            if (waited >= timeout_ms or !self.running.load(.acquire)) return null;
            self.io.sleep(.fromMilliseconds(step_ms), clock) catch return null;
            waited += step_ms;
        }
    }

    fn stderrLoop(self: *LspClient) void {
        const stderr = self.zls_stderr orelse return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr.readStreaming(self.io, &.{&buf}) catch return;
            if (n == 0) return;
            log("ZLS stderr: {s}", .{buf[0..n]});
        }
    }

    /// Wake every pending request (e.g. when ZLS dies). They observe a null
    /// response and fail with `NoResponse` instead of hanging.
    fn signalAllPending(self: *LspClient) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.event.set(self.io);
        }
    }

    /// Tear down the LSP session.
    ///
    /// Contract: the ZLS process must already be dead or exiting. Closing the
    /// stdout descriptor while the reader thread is blocked on it would not
    /// wake that thread, and the freed descriptor number would immediately be
    /// reused by the next spawn — so stdin is closed first (ZLS exits on stdin
    /// EOF), the threads are joined on the resulting EOF, and only then are the
    /// remaining descriptors closed.
    pub fn disconnect(self: *LspClient) void {
        self.running.store(false, .release);

        if (self.zls_stdin) |stdin| {
            stdin.close(self.io);
            self.zls_stdin = null;
        }

        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        if (self.stderr_thread) |t| {
            t.join();
            self.stderr_thread = null;
        }

        if (self.zls_stdout) |stdout| {
            stdout.close(self.io);
            self.zls_stdout = null;
        }
        if (self.zls_stderr) |se| {
            se.close(self.io);
            self.zls_stderr = null;
        }

        self.signalAllPending();
    }

    pub fn deinit(self: *LspClient) void {
        self.disconnect();

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            self.destroyPending(entry.value_ptr.*);
        }
        self.pending.deinit(self.allocator);

        var d_it = self.diagnostics.iterator();
        while (d_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.diagnostics.deinit(self.allocator);
    }

    fn log(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[zig-mcp/lsp] " ++ fmt ++ "\n", args);
    }
};

// ── Tests ──

test "LspClient init creates disconnected client" {
    const alloc = std.testing.allocator;
    var client = LspClient.init(alloc, testing.io());
    defer client.deinit();

    try std.testing.expect(client.zls_stdin == null);
    try std.testing.expect(client.zls_stdout == null);
    try std.testing.expect(client.reader_thread == null);
    try std.testing.expect(!client.isConnected());
}

test "sendRequest returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    var client = LspClient.init(alloc, testing.io());
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendRequest(alloc, "textDocument/hover", .{}));
}

test "sendNotification returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    var client = LspClient.init(alloc, testing.io());
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendNotification(alloc, "textDocument/didOpen", .{}));
}

test "sendRawNotification returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    var client = LspClient.init(alloc, testing.io());
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendRawNotification(alloc, "initialized"));
}

test "disconnect on already disconnected client is safe" {
    const alloc = std.testing.allocator;
    var client = LspClient.init(alloc, testing.io());
    defer client.deinit();

    client.disconnect();
    client.disconnect();
}

test "request is answered by the matching response" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    const responder = try std.Thread.spawn(.{}, respondToNext, .{ &fake, alloc, "{\"ok\":true}" });
    defer responder.join();

    const response = try fake.client.sendRequest(alloc, "textDocument/hover", .{});
    defer alloc.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
}

test "response for an unknown id is ignored" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    const Helper = struct {
        fn run(f: *FakeZls, a: std.mem.Allocator) !void {
            const req = (try f.nextRequest(a)).?;
            defer a.free(req);
            // Answer a completely different id first, then the real one.
            try f.reply("{\"jsonrpc\":\"2.0\",\"id\":9999,\"result\":\"wrong\"}");

            const parsed = try std.json.parseFromSlice(std.json.Value, a, req, .{});
            defer parsed.deinit();
            const id = parsed.value.object.get("id").?.integer;
            const msg = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"right\"}}", .{id});
            defer a.free(msg);
            try f.reply(msg);
        }
    };
    const responder = try std.Thread.spawn(.{}, Helper.run, .{ &fake, alloc });
    defer responder.join();

    const response = try fake.client.sendRequest(alloc, "textDocument/hover", .{});
    defer alloc.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "right") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "wrong") == null);
}

test "server-initiated request is not mistaken for a response" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    const Helper = struct {
        fn run(f: *FakeZls, a: std.mem.Allocator) !void {
            const req = (try f.nextRequest(a)).?;
            defer a.free(req);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, req, .{});
            defer parsed.deinit();
            const id = parsed.value.object.get("id").?.integer;

            // ZLS asks *us* something, reusing the same id number.
            const server_req = try std.fmt.allocPrint(
                a,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"client/registerCapability\",\"params\":{{}}}}",
                .{id},
            );
            defer a.free(server_req);
            try f.reply(server_req);

            // Our rejection comes back on the request pipe; drain it.
            const rejection = (try f.nextRequest(a)).?;
            defer a.free(rejection);
            try std.testing.expect(std.mem.indexOf(u8, rejection, "-32601") != null);

            const msg = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"real\"}}", .{id});
            defer a.free(msg);
            try f.reply(msg);
        }
    };
    const responder = try std.Thread.spawn(.{}, Helper.run, .{ &fake, alloc });
    defer responder.join();

    const response = try fake.client.sendRequest(alloc, "textDocument/hover", .{});
    defer alloc.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "real") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "registerCapability") == null);
}

test "ZLS death mid-request fails that request instead of hanging" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    const Helper = struct {
        fn run(f: *FakeZls, a: std.mem.Allocator) !void {
            const req = (try f.nextRequest(a)).?;
            defer a.free(req);
            f.kill();
        }
    };
    const killer = try std.Thread.spawn(.{}, Helper.run, .{ &fake, alloc });
    defer killer.join();

    try std.testing.expectError(error.NoResponse, fake.client.sendRequest(alloc, "textDocument/hover", .{}));
}

test "requests after ZLS death fail fast" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    fake.kill();
    // Reader thread must observe EOF and mark the session dead.
    while (fake.client.isConnected()) {
        fake.io.sleep(.fromMilliseconds(5), .awake) catch break;
    }

    const started = std.Io.Clock.now(.awake, fake.io);
    try std.testing.expectError(error.NotConnected, fake.client.sendRequest(alloc, "textDocument/hover", .{}));
    const elapsed = std.Io.Clock.now(.awake, fake.io).nanoseconds - started.nanoseconds;
    // Nowhere near the 300 ms request timeout, let alone the 30 s default.
    try std.testing.expect(elapsed < std.time.ns_per_ms * 100);
}

test "request that is never answered times out" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    try std.testing.expectError(error.RequestTimeout, fake.client.sendRequest(alloc, "textDocument/hover", .{}));
}

test "late response after timeout does not leak or corrupt" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    try std.testing.expectError(error.RequestTimeout, fake.client.sendRequest(alloc, "textDocument/hover", .{}));

    // The answer shows up after the requester gave up; it must be dropped.
    const req = (try fake.nextRequest(alloc)).?;
    defer alloc.free(req);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, req, .{});
    defer parsed.deinit();
    const id = parsed.value.object.get("id").?.integer;
    const msg = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"late\"}}", .{id});
    defer alloc.free(msg);
    try fake.reply(msg);

    const responder = try std.Thread.spawn(.{}, respondToNext, .{ &fake, alloc, "\"second\"" });
    defer responder.join();

    const response = try fake.client.sendRequest(alloc, "textDocument/hover", .{});
    defer alloc.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "late") == null);
}

test "publishDiagnostics notifications are cached per uri" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    try fake.reply(
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.zig","diagnostics":[{"message":"boom","severity":1}]}}
    );

    const diags = (try fake.client.waitForDiagnostics(alloc, "file:///a.zig", 2000)).?;
    defer alloc.free(diags);
    try std.testing.expect(std.mem.indexOf(u8, diags, "boom") != null);

    fake.client.clearDiagnostics("file:///a.zig");
    try std.testing.expect(try fake.client.getDiagnostics(alloc, "file:///a.zig") == null);
}

test "diagnostics for a uri are replaced, not accumulated" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    try fake.reply(
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.zig","diagnostics":[{"message":"first"}]}}
    );
    const first = (try fake.client.waitForDiagnostics(alloc, "file:///a.zig", 2000)).?;
    alloc.free(first);

    try fake.reply(
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.zig","diagnostics":[]}}
    );
    // Poll until the replacement lands.
    var replaced = false;
    for (0..200) |_| {
        const current = (try fake.client.getDiagnostics(alloc, "file:///a.zig")).?;
        defer alloc.free(current);
        if (std.mem.eql(u8, current, "[]")) {
            replaced = true;
            break;
        }
        fake.io.sleep(.fromMilliseconds(5), .awake) catch break;
    }
    try std.testing.expect(replaced);
    try std.testing.expectEqual(@as(u32, 1), fake.client.diagnostics.count());
}

test "malformed LSP traffic does not kill the reader" {
    const alloc = std.testing.allocator;
    var fake = try FakeZls.init(alloc);
    try fake.start();
    defer fake.deinit();

    try fake.reply("not json at all");
    try fake.reply("[1,2,3]");
    try fake.reply("{\"jsonrpc\":\"2.0\"}");

    const responder = try std.Thread.spawn(.{}, respondToNext, .{ &fake, alloc, "\"still alive\"" });
    defer responder.join();

    const response = try fake.client.sendRequest(alloc, "textDocument/hover", .{});
    defer alloc.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "still alive") != null);
}

test "writeJsonStringBody escapes quotes, backslashes and control characters" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try LspClient.writeJsonStringBody(&aw.writer, "a\"b\\c\nd");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\u000ad", aw.written());
}
