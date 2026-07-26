const std = @import("std");
const LspClient = @import("../lsp/client.zig").LspClient;
const lsp_types = @import("../lsp/types.zig");
const uri_util = @import("../types/uri.zig");
const PosixMutex = @import("../sync.zig").PosixMutex;
const testing = @import("../testing.zig");

/// Largest source file we will hand to ZLS.
pub const max_file_bytes: usize = 10 * 1024 * 1024;

/// Tracks which documents are open in the LSP session and keeps their contents
/// in sync.
///
/// ZLS answers from the text it was given, not from disk, so a document opened
/// once and never updated makes every later hover/definition/reference answer
/// stale as soon as the file is edited. Every sync therefore re-reads the file
/// and sends `didChange` when the contents actually differ.
pub const DocumentState = struct {
    open_docs: std.StringHashMapUnmanaged(DocInfo),
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    io: std.Io,
    mutex: PosixMutex = .{},

    const DocInfo = struct {
        version: i64,
        /// Hash of the text ZLS currently holds for this document.
        content_hash: u64,
    };

    /// Outcome of a `sync` call.
    pub const SyncResult = struct {
        /// Document URI, allocated with the caller's allocator.
        uri: []const u8,
        /// True when `didOpen` or `didChange` was just sent, meaning any
        /// previously published diagnostics for this URI are now stale.
        changed: bool,
    };

    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8, io: std.Io) DocumentState {
        return .{
            .open_docs = .empty,
            .allocator = allocator,
            .workspace_path = workspace_path,
            .io = io,
        };
    }

    /// Ensure `file_path` is open in ZLS and up to date.
    /// `file_path` may be relative (resolved against the workspace) or absolute.
    /// Returns a URI allocated with `ret_allocator` (caller must free).
    pub fn ensureOpen(
        self: *DocumentState,
        lsp_client: *LspClient,
        file_path: []const u8,
        ret_allocator: std.mem.Allocator,
    ) ![]const u8 {
        const result = try self.sync(lsp_client, file_path, ret_allocator);
        return result.uri;
    }

    /// Like `ensureOpen`, but also reports whether the document contents just
    /// changed from ZLS's point of view.
    pub fn sync(
        self: *DocumentState,
        lsp_client: *LspClient,
        file_path: []const u8,
        ret_allocator: std.mem.Allocator,
    ) !SyncResult {
        const abs_path = try uri_util.resolvePath(self.allocator, self.workspace_path, file_path);
        defer self.allocator.free(abs_path);

        const file_uri = try uri_util.pathToUri(self.allocator, abs_path);
        defer self.allocator.free(file_uri);

        // File I/O happens outside the lock.
        const content = try self.readSource(abs_path);
        defer self.allocator.free(content);
        const hash = std.hash.Wyhash.hash(0, content);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.open_docs.getPtr(file_uri)) |info| {
            if (info.content_hash == hash) {
                return .{ .uri = try ret_allocator.dupe(u8, file_uri), .changed = false };
            }

            const next_version = info.version + 1;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            try lsp_client.sendNotification(arena.allocator(), "textDocument/didChange", lsp_types.DidChangeTextDocumentParams{
                .textDocument = .{ .uri = file_uri, .version = next_version },
                .contentChanges = &.{.{ .text = content }},
            });

            info.version = next_version;
            info.content_hash = hash;
            lsp_client.clearDiagnostics(file_uri);
            return .{ .uri = try ret_allocator.dupe(u8, file_uri), .changed = true };
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        try lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", lsp_types.DidOpenTextDocumentParams{
            .textDocument = .{
                .uri = file_uri,
                .languageId = "zig",
                .version = 1,
                .text = content,
            },
        });

        const stored_uri = try self.allocator.dupe(u8, file_uri);
        errdefer self.allocator.free(stored_uri);
        try self.open_docs.put(self.allocator, stored_uri, .{
            .version = 1,
            .content_hash = hash,
        });

        lsp_client.clearDiagnostics(file_uri);
        return .{ .uri = try ret_allocator.dupe(u8, file_uri), .changed = true };
    }

    fn readSource(self: *DocumentState, abs_path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            self.io,
            abs_path,
            self.allocator,
            std.Io.Limit.limited(max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.FileReadError,
        };
    }

    /// Close a document in ZLS.
    pub fn closeDoc(self: *DocumentState, lsp_client: *LspClient, file_uri: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.open_docs.fetchRemove(file_uri)) |kv| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            lsp_client.sendNotification(arena.allocator(), "textDocument/didClose", lsp_types.DidCloseTextDocumentParams{
                .textDocument = .{ .uri = file_uri },
            }) catch |err| {
                std.debug.print("[zig-mcp/docs] didClose notification failed: {s}\n", .{@errorName(err)});
            };

            self.allocator.free(kv.key);
            lsp_client.clearDiagnostics(file_uri);
        }
    }

    /// Reopen all tracked documents in a new ZLS session (after reconnect).
    pub fn reopenAll(self: *DocumentState, lsp_client: *LspClient) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.open_docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.key_ptr.*;

            // The URI is percent-encoded; a path with a space would not open.
            const path = uri_util.uriToPath(self.allocator, uri) catch continue;
            defer self.allocator.free(path);

            const content = self.readSource(path) catch {
                std.debug.print("[zig-mcp/docs] Failed to re-read {s} for reopen\n", .{path});
                continue;
            };
            defer self.allocator.free(content);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", lsp_types.DidOpenTextDocumentParams{
                .textDocument = .{
                    .uri = uri,
                    .languageId = "zig",
                    .version = entry.value_ptr.version,
                    .text = content,
                },
            }) catch |err| {
                std.debug.print("[zig-mcp/docs] Failed to reopen {s}: {s}\n", .{ path, @errorName(err) });
                continue;
            };

            entry.value_ptr.content_hash = std.hash.Wyhash.hash(0, content);
            lsp_client.clearDiagnostics(uri);
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

// ── Tests ──

/// A `DocumentState` over a scratch directory, wired to a disconnected client
/// (notifications fail with `NotConnected`, which the tests tolerate where the
/// point is the bookkeeping rather than the wire traffic).
const Fixture = struct {
    ws: testing.TmpWorkspace,
    docs: DocumentState,
    client: LspClient,
    alloc: std.mem.Allocator,

    /// Two-phase: `docs` must point at `ws.root`, which is only stable once the
    /// fixture sits at its final address.
    fn init(alloc: std.mem.Allocator) !Fixture {
        return .{
            .ws = try testing.TmpWorkspace.init(alloc),
            // SAFETY: assigned by `start`, which every test calls before
            // touching `docs`. It borrows `ws.root`, which is only stable
            // once this struct is at its final address.
            .docs = undefined,
            .client = LspClient.init(alloc, testing.io()),
            .alloc = alloc,
        };
    }

    fn start(self: *Fixture) void {
        self.docs = DocumentState.init(self.alloc, self.ws.root, testing.io());
    }

    fn write(self: *Fixture, name: []const u8, contents: []const u8) !void {
        try self.ws.writeFile(name, contents);
    }

    /// URI of a workspace file, as `DocumentState` would compute it.
    fn uriOf(self: *Fixture, name: []const u8) ![]const u8 {
        const abs = try self.ws.path(name);
        defer self.alloc.free(abs);
        return uri_util.pathToUri(self.alloc, abs);
    }

    fn deinit(self: *Fixture) void {
        self.docs.deinit();
        self.client.deinit();
        self.ws.deinit();
    }
};

test "DocumentState init and deinit" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp/workspace", testing.io());
    defer ds.deinit();

    try std.testing.expectEqualStrings("/tmp/workspace", ds.workspace_path);
    try std.testing.expectEqual(@as(u32, 0), ds.open_docs.count());
}

test "sync reports FileNotFound for a missing file" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();

    try std.testing.expectError(error.FileNotFound, fx.docs.sync(&fx.client, "nope.zig", alloc));
    try std.testing.expectEqual(@as(u32, 0), fx.docs.open_docs.count());
}

test "a failed didOpen does not mark the document as open" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();
    try fx.write("a.zig", "const a = 1;");

    // No ZLS attached, so the notification fails — but only after the read.
    try std.testing.expectError(error.NotConnected, fx.docs.sync(&fx.client, "a.zig", alloc));
    // Otherwise the document would be considered open and never sent again.
    try std.testing.expectEqual(@as(u32, 0), fx.docs.open_docs.count());
}

test "unchanged file is not resent" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();
    try fx.write("a.zig", "const a = 1;");

    const uri = try fx.uriOf("a.zig");
    defer alloc.free(uri);

    // Pretend the didOpen succeeded by registering the document directly.
    const stored = try alloc.dupe(u8, uri);
    try fx.docs.open_docs.put(alloc, stored, .{
        .version = 1,
        .content_hash = std.hash.Wyhash.hash(0, "const a = 1;"),
    });

    const result = try fx.docs.sync(&fx.client, "a.zig", alloc);
    defer alloc.free(result.uri);
    try std.testing.expect(!result.changed);
    try std.testing.expectEqualStrings(uri, result.uri);
    try std.testing.expectEqual(@as(i64, 1), fx.docs.open_docs.get(uri).?.version);
}

test "edited file is detected and the version only advances on success" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();
    try fx.write("a.zig", "const a = 1;");

    const uri = try fx.uriOf("a.zig");
    defer alloc.free(uri);
    const stored = try alloc.dupe(u8, uri);
    try fx.docs.open_docs.put(alloc, stored, .{
        .version = 1,
        .content_hash = std.hash.Wyhash.hash(0, "const a = 1;"),
    });

    // Edit on disk: the next sync must try to push a didChange.
    try fx.write("a.zig", "const a = 2;");
    try std.testing.expectError(error.NotConnected, fx.docs.sync(&fx.client, "a.zig", alloc));

    // The notification failed, so neither the version nor the hash may advance
    // — otherwise ZLS would be permanently out of sync with the file.
    try std.testing.expectEqual(@as(i64, 1), fx.docs.open_docs.get(uri).?.version);
    try std.testing.expectEqual(
        std.hash.Wyhash.hash(0, "const a = 1;"),
        fx.docs.open_docs.get(uri).?.content_hash,
    );
}

test "closeDoc removes tracking" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();

    const stored = try alloc.dupe(u8, "file:///x.zig");
    try fx.docs.open_docs.put(alloc, stored, .{ .version = 1, .content_hash = 0 });

    try fx.docs.closeDoc(&fx.client, "file:///x.zig");
    try std.testing.expectEqual(@as(u32, 0), fx.docs.open_docs.count());
}

test "closeDoc on an unknown uri is a no-op" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();

    try fx.docs.closeDoc(&fx.client, "file:///never-opened.zig");
    try std.testing.expectEqual(@as(u32, 0), fx.docs.open_docs.count());
}

test "tracked uris resolve back to readable paths" {
    // `reopenAll` turns each tracked URI back into a path. Using the raw
    // `file://` suffix leaves `%20` in place, so any file with a space in its
    // name silently failed to reopen after a ZLS restart.
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();
    try fx.write("my file.zig", "const a = 1;");

    const uri = try fx.uriOf("my file.zig");
    defer alloc.free(uri);
    try std.testing.expect(std.mem.indexOf(u8, uri, "%20") != null);

    const path = try uri_util.uriToPath(alloc, uri);
    defer alloc.free(path);
    const content = try fx.docs.readSource(path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("const a = 1;", content);
}

test "reopenAll on a dead client leaves tracking intact" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    fx.start();
    defer fx.deinit();
    try fx.write("my file.zig", "const a = 1;");

    const uri = try fx.uriOf("my file.zig");
    defer alloc.free(uri);
    const stored = try alloc.dupe(u8, uri);
    try fx.docs.open_docs.put(alloc, stored, .{ .version = 3, .content_hash = 0 });

    fx.docs.reopenAll(&fx.client);
    // The didOpen could not be sent, so the recorded hash must stay stale
    // rather than claim ZLS has the current text.
    try std.testing.expectEqual(@as(u64, 0), fx.docs.open_docs.get(uri).?.content_hash);
}
