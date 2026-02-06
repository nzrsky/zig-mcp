const std = @import("std");
const LspClient = @import("../lsp/client.zig").LspClient;
const uri_util = @import("../types/uri.zig");

/// Tracks which documents are open in the LSP session.
/// Sends didOpen/didClose notifications as needed.
pub const DocumentState = struct {
    open_docs: std.StringHashMapUnmanaged(DocInfo),
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    mutex: std.Thread.Mutex = .{},

    const DocInfo = struct {
        version: i64,
        uri: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8) DocumentState {
        return .{
            .open_docs = .empty,
            .allocator = allocator,
            .workspace_path = workspace_path,
        };
    }

    /// Ensure a file is open in ZLS. Reads file content and sends didOpen if not already open.
    /// `file_path` can be relative (resolved against workspace) or absolute.
    /// Returns a URI allocated with `ret_allocator` (caller must free).
    pub fn ensureOpen(self: *DocumentState, lsp_client: *LspClient, file_path: []const u8, ret_allocator: std.mem.Allocator) ![]const u8 {
        const abs_path = try uri_util.resolvePath(self.allocator, self.workspace_path, file_path);
        defer self.allocator.free(abs_path);

        const file_uri = try uri_util.pathToUri(self.allocator, abs_path);
        defer self.allocator.free(file_uri);

        // Fast path: check under lock, return immediately if already open
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.open_docs.get(file_uri)) |_| {
                return try ret_allocator.dupe(u8, file_uri);
            }
        }

        // Slow path: read file content outside the lock (no mutex held during I/O)
        const content = std.fs.cwd().readFileAlloc(self.allocator, abs_path, 10 * 1024 * 1024) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                else => error.FileReadError,
            };
        };
        defer self.allocator.free(content);

        // Re-acquire lock, double-check, then register
        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-check: another thread may have opened it while we were reading
        if (self.open_docs.get(file_uri)) |_| {
            return try ret_allocator.dupe(u8, file_uri);
        }

        // Send didOpen notification (still under lock to prevent duplicate opens)
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const DidOpenParams = struct {
            textDocument: struct {
                uri: []const u8,
                languageId: []const u8,
                version: i64,
                text: []const u8,
            },
        };

        try lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", DidOpenParams{
            .textDocument = .{
                .uri = file_uri,
                .languageId = "zig",
                .version = 1,
                .text = content,
            },
        });

        // Track as open (stored with long-lived allocator)
        const stored_uri = try self.allocator.dupe(u8, file_uri);
        try self.open_docs.put(self.allocator, stored_uri, .{
            .version = 1,
            .uri = stored_uri,
        });

        return try ret_allocator.dupe(u8, file_uri);
    }

    /// Close a document in ZLS.
    pub fn closeDoc(self: *DocumentState, lsp_client: *LspClient, file_uri: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.open_docs.fetchRemove(file_uri)) |kv| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const CloseParams = struct {
                textDocument: struct { uri: []const u8 },
            };
            lsp_client.sendNotification(arena.allocator(), "textDocument/didClose", CloseParams{
                .textDocument = .{ .uri = file_uri },
            }) catch |err| {
                std.debug.print("[zig-mcp/docs] didClose notification failed: {}\n", .{err});
            };

            self.allocator.free(kv.key);
        }
    }

    /// Reopen all tracked documents in a new ZLS session (after reconnect).
    pub fn reopenAll(self: *DocumentState, lsp_client: *LspClient) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.open_docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;

            // Convert URI back to path for re-reading
            const path = if (std.mem.startsWith(u8, uri, "file://"))
                uri[7..]
            else
                uri;

            const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch {
                std.debug.print("[zig-mcp/docs] Failed to re-read {s} for reopen\n", .{path});
                continue;
            };
            defer self.allocator.free(content);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const DidOpenParams = struct {
                textDocument: struct {
                    uri: []const u8,
                    languageId: []const u8,
                    version: i64,
                    text: []const u8,
                },
            };

            lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", DidOpenParams{
                .textDocument = .{
                    .uri = uri,
                    .languageId = "zig",
                    .version = entry.value_ptr.version,
                    .text = content,
                },
            }) catch |err| {
                std.debug.print("[zig-mcp/docs] Failed to reopen {s}: {}\n", .{ path, err });
            };
        }
    }

    pub fn deinit(self: *DocumentState) void {
        var it = self.open_docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.open_docs.deinit(self.allocator);
    }
};
