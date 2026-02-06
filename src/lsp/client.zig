const std = @import("std");
const LspTransport = @import("transport.zig").LspTransport;
const json_rpc = @import("../types/json_rpc.zig");

/// Pending request waiting for a response from ZLS.
const PendingRequest = struct {
    response: ?[]const u8 = null,
    event: std.Thread.ResetEvent = .{},
    allocator: std.mem.Allocator,
};

/// LSP Client: manages request/response correlation with the ZLS child process.
///
/// Architecture:
/// - Main thread calls sendRequest() which blocks until reader thread delivers the response.
/// - Reader thread runs readerLoop() reading ZLS stdout and dispatching responses/notifications.
pub const LspClient = struct {
    zls_stdin: ?std.fs.File,
    zls_stdout: ?std.fs.File,
    next_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    pending: std.AutoHashMapUnmanaged(i64, *PendingRequest),
    pending_mutex: std.Thread.Mutex = .{},
    reader_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,
    notification_callback: ?*const fn (method: []const u8, params: ?std.json.Value) void = null,
    diagnostics_callback: ?*const fn ([]const u8, []const u8) void = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stderr_thread: ?std.Thread = null,
    zls_stderr: ?std.fs.File = null,

    pub fn init(allocator: std.mem.Allocator) LspClient {
        return .{
            .zls_stdin = null,
            .zls_stdout = null,
            .pending = .empty,
            .allocator = allocator,
        };
    }

    /// Connect to ZLS pipes and start reader thread.
    pub fn connect(self: *LspClient, stdin: std.fs.File, stdout: std.fs.File, stderr: ?std.fs.File) !void {
        self.zls_stdin = stdin;
        self.zls_stdout = stdout;
        self.zls_stderr = stderr;
        self.running.store(true, .release);

        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});

        if (stderr) |se| {
            self.stderr_thread = try std.Thread.spawn(.{}, stderrLoop, .{se});
        }
    }

    /// Send an LSP request and block until the response arrives.
    /// Returns owned response JSON body, or error on timeout/failure.
    pub fn sendRequest(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype) ![]const u8 {
        const stdin = self.zls_stdin orelse return error.NotConnected;
        const id = self.next_id.fetchAdd(1, .monotonic);

        // Create pending request
        const pending = try self.allocator.create(PendingRequest);
        pending.* = .{ .allocator = self.allocator };

        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            try self.pending.put(self.allocator, id, pending);
        }

        errdefer {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(id);
            self.allocator.destroy(pending);
        }

        // Write LSP request
        const msg = try json_rpc.writeRequest(allocator, .{ .integer = id }, method, params);
        defer allocator.free(msg);
        try LspTransport.writeMessage(stdin, msg);

        // Wait for response (30s timeout)
        pending.event.timedWait(30 * std.time.ns_per_s) catch {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(id);
            self.allocator.destroy(pending);
            return error.RequestTimeout;
        };

        // Get response
        const response = pending.response orelse {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(id);
            self.allocator.destroy(pending);
            return error.NoResponse;
        };

        // Cleanup
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(id);
        }
        self.allocator.destroy(pending);

        // Dupe to caller's allocator (free original on success or OOM)
        defer self.allocator.free(response);
        return try allocator.dupe(u8, response);
    }

    /// Send an LSP notification (no response expected).
    pub fn sendNotification(self: *LspClient, allocator: std.mem.Allocator, method: []const u8, params: anytype) !void {
        const stdin = self.zls_stdin orelse return error.NotConnected;
        const msg = try json_rpc.writeNotification(allocator, method, params);
        defer allocator.free(msg);
        try LspTransport.writeMessage(stdin, msg);
    }

    /// Send a notification with empty params object (avoids [] vs {} serialization issue).
    pub fn sendRawNotification(self: *LspClient, allocator: std.mem.Allocator, method: []const u8) !void {
        const stdin = self.zls_stdin orelse return error.NotConnected;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
        , .{method});
        const msg = try aw.toOwnedSlice();
        defer allocator.free(msg);
        try LspTransport.writeMessage(stdin, msg);
    }

    /// Send LSP initialize request and initialized notification.
    pub fn initialize(self: *LspClient, allocator: std.mem.Allocator, workspace_uri: []const u8) ![]const u8 {
        // Build init params as JSON manually for full control

        // Build init params as json.Value manually for more control
        const init_json =
            \\{"processId":null,"rootUri":"
        ;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.writeAll(init_json);
        // Escape the URI
        for (workspace_uri) |c| {
            switch (c) {
                '"' => try aw.writer.writeAll("\\\""),
                '\\' => try aw.writer.writeAll("\\\\"),
                else => try aw.writer.writeByte(c),
            }
        }
        try aw.writer.writeAll(
            \\","capabilities":{"textDocument":{"hover":{"contentFormat":["markdown","plaintext"]},"completion":{"completionItem":{"snippetSupport":false}},"signatureHelp":{"signatureInformation":{"documentationFormat":["markdown","plaintext"]}},"publishDiagnostics":{"relatedInformation":true}}}}
        );
        const init_params_json = try aw.toOwnedSlice();
        defer allocator.free(init_params_json);

        // Build the full request manually
        const id = self.next_id.fetchAdd(1, .monotonic);
        const pending = try self.allocator.create(PendingRequest);
        pending.* = .{ .allocator = self.allocator };

        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            try self.pending.put(self.allocator, id, pending);
        }

        // Write raw LSP request
        var req_aw: std.Io.Writer.Allocating = .init(allocator);
        defer req_aw.deinit();
        try req_aw.writer.print(
            \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":
        , .{id});
        try req_aw.writer.writeAll(init_params_json);
        try req_aw.writer.writeByte('}');
        const req_json = try req_aw.toOwnedSlice();
        defer allocator.free(req_json);

        const stdin = self.zls_stdin orelse return error.NotConnected;
        try LspTransport.writeMessage(stdin, req_json);

        // Wait for response
        pending.event.timedWait(30 * std.time.ns_per_s) catch {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(id);
            self.allocator.destroy(pending);
            return error.RequestTimeout;
        };

        const response = pending.response orelse {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(id);
            self.allocator.destroy(pending);
            return error.NoResponse;
        };

        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(id);
        }
        self.allocator.destroy(pending);

        // Dupe response to caller allocator (free original on success or OOM)
        defer self.allocator.free(response);
        const duped = try allocator.dupe(u8, response);

        // Send initialized notification (must send empty object {}, not [])
        try self.sendRawNotification(allocator, "initialized");

        return duped;
    }

    /// Background thread: reads LSP messages from ZLS stdout, dispatches responses.
    fn readerLoop(self: *LspClient) void {
        const stdout = self.zls_stdout orelse return;
        var reader = LspTransport.Reader.init(stdout);

        while (self.running.load(.acquire)) {
            const msg = reader.readMessage(self.allocator) catch |err| {
                log("LSP reader error: {}", .{err});
                self.signalAllPending();
                return;
            };
            if (msg == null) {
                // ZLS closed stdout (crashed or exited)
                log("ZLS stdout closed", .{});
                self.signalAllPending();
                return;
            }
            const data = msg.?;
            defer self.allocator.free(data);

            // Parse to check if it's a response (has "id") or notification (has "method")
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
                log("Failed to parse LSP message", .{});
                continue;
            };
            defer parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };

            if (obj.get("id")) |id_val| {
                // Response — find pending request
                const id: i64 = switch (id_val) {
                    .integer => |i| i,
                    else => continue,
                };

                self.pending_mutex.lock();
                const maybe_pending = self.pending.get(id);
                self.pending_mutex.unlock();

                if (maybe_pending) |p| {
                    // Store the full response body
                    p.response = self.allocator.dupe(u8, data) catch null;
                    p.event.set();
                }
            }
            // Notifications (diagnostics etc.) are silently dropped for now.
            // TODO: store diagnostics for zig_diagnostics tool
        }
    }

    fn stderrLoop(stderr: std.fs.File) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr.read(&buf) catch return;
            if (n == 0) return;
            log("ZLS stderr: {s}", .{buf[0..n]});
        }
    }

    /// Signal all pending requests (e.g., when ZLS crashes).
    fn signalAllPending(self: *LspClient) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.event.set();
        }
    }

    pub fn disconnect(self: *LspClient) void {
        self.running.store(false, .release);
        // Close all pipes to signal ZLS to exit and unblock reader threads
        if (self.zls_stdin) |stdin| {
            stdin.close();
            self.zls_stdin = null;
        }
        if (self.zls_stdout) |stdout| {
            stdout.close();
            self.zls_stdout = null;
        }
        if (self.zls_stderr) |se| {
            se.close();
            self.zls_stderr = null;
        }
        // Now safe to join — readers will see EOF from closed pipes
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        if (self.stderr_thread) |t| {
            t.join();
            self.stderr_thread = null;
        }
    }

    pub fn deinit(self: *LspClient) void {
        self.disconnect();
        // Free any remaining pending requests
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.response) |r| {
                self.allocator.free(r);
            }
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pending.deinit(self.allocator);
    }

    fn log(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[zig-mcp/lsp] " ++ fmt ++ "\n", args);
    }
};
