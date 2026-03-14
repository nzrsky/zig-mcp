const std = @import("std");
const compat = @import("../compat.zig");

/// Manages ZLS child process lifecycle: spawn, health check, restart.
pub const ZlsProcess = struct {
    child: ?std.process.Child = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    zls_path: []const u8,
    restart_count: u32 = 0,
    max_restarts: u32 = 5,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, zls_path: []const u8) ZlsProcess {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_path = workspace_path,
            .zls_path = zls_path,
        };
    }

    /// Spawn the ZLS child process with piped stdin/stdout/stderr.
    pub fn spawn(self: *ZlsProcess) !void {
        if (self.child != null) {
            self.kill();
        }

        const child = try std.process.spawn(self.io, .{
            .argv = &.{self.zls_path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        self.child = child;
    }

    /// Get the stdin pipe for writing to ZLS.
    pub fn getStdin(self: *ZlsProcess) ?compat.File {
        const child = self.child orelse return null;
        const f = child.stdin orelse return null;
        return compat.File.fromIoFile(f);
    }

    /// Get the stdout pipe for reading from ZLS.
    pub fn getStdout(self: *ZlsProcess) ?compat.File {
        const child = self.child orelse return null;
        const f = child.stdout orelse return null;
        return compat.File.fromIoFile(f);
    }

    /// Get the stderr pipe for reading ZLS stderr.
    pub fn getStderr(self: *ZlsProcess) ?compat.File {
        const child = self.child orelse return null;
        const f = child.stderr orelse return null;
        return compat.File.fromIoFile(f);
    }

    /// Check if ZLS is currently alive.
    pub fn isAlive(self: *ZlsProcess) bool {
        return self.child != null;
    }

    /// Kill the ZLS child process.
    pub fn kill(self: *ZlsProcess) void {
        if (self.child) |*child| {
            // Close stdin to signal ZLS to exit (if not already closed)
            if (child.stdin) |f| {
                compat.File.fromIoFile(f).close();
                child.stdin = null;
            }
            // Close stdout/stderr to unblock reader threads
            if (child.stdout) |f| {
                compat.File.fromIoFile(f).close();
                child.stdout = null;
            }
            if (child.stderr) |f| {
                compat.File.fromIoFile(f).close();
                child.stderr = null;
            }
            _ = child.wait(self.io) catch {};
            self.child = null;
        }
    }

    /// Mark pipe handles as externally owned (e.g., by LspClient).
    /// Prevents double-close during deinit.
    pub fn detachPipes(self: *ZlsProcess) void {
        if (self.child) |*child| {
            child.stdin = null;
            child.stdout = null;
            child.stderr = null;
        }
    }

    /// Attempt to restart ZLS. Returns false if max restarts exceeded.
    pub fn restart(self: *ZlsProcess) !bool {
        if (self.restart_count >= self.max_restarts) {
            return false;
        }
        self.kill();
        self.restart_count += 1;
        self.spawn() catch return false;
        return true;
    }

    pub fn deinit(self: *ZlsProcess) void {
        self.kill();
    }
};

// ── Tests ──

test "ZlsProcess init state" {
    const alloc = std.testing.allocator;
    var proc = ZlsProcess.init(alloc, std.testing.io, "/workspace", "/usr/bin/zls");
    defer proc.deinit();
    try std.testing.expect(!proc.isAlive());
    try std.testing.expect(proc.getStdin() == null);
    try std.testing.expect(proc.getStdout() == null);
    try std.testing.expect(proc.getStderr() == null);
    try std.testing.expectEqual(@as(u32, 0), proc.restart_count);
}

test "ZlsProcess detachPipes on null child" {
    const alloc = std.testing.allocator;
    var proc = ZlsProcess.init(alloc, std.testing.io, "/workspace", "/usr/bin/zls");
    proc.detachPipes(); // should not crash
    try std.testing.expect(!proc.isAlive());
}

test "ZlsProcess kill on null child" {
    const alloc = std.testing.allocator;
    var proc = ZlsProcess.init(alloc, std.testing.io, "/workspace", "/usr/bin/zls");
    proc.kill(); // should not crash
    try std.testing.expect(!proc.isAlive());
}

test "ZlsProcess max restart count" {
    const alloc = std.testing.allocator;
    var proc = ZlsProcess.init(alloc, std.testing.io, "/workspace", "/nonexistent-zls-binary");
    defer proc.deinit();
    proc.max_restarts = 3;

    // Each restart attempt will fail because binary doesn't exist, but count increments
    for (0..3) |_| {
        _ = proc.restart() catch false;
    }
    try std.testing.expectEqual(@as(u32, 3), proc.restart_count);

    // Now should return false (max exceeded)
    const can_restart = proc.restart() catch false;
    try std.testing.expect(!can_restart);
}

/// Find ZLS binary. Checks: PATH lookup, common locations, home directory.
pub fn findZls(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map) ![]const u8 {
    // Try PATH first via std.process.run
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "which", "zls" },
    }) catch null;
    if (result) |r| {
        defer allocator.free(r.stderr);
        if (r.term == .exited and r.term.exited == 0 and r.stdout.len > 0) {
            // Trim trailing newline
            const trimmed = std.mem.trimEnd(u8, r.stdout, "\n\r ");
            const path = allocator.dupe(u8, trimmed) catch {
                allocator.free(r.stdout);
                return error.OutOfMemory;
            };
            allocator.free(r.stdout);
            return path;
        }
        allocator.free(r.stdout);
    }

    // Common locations
    const common_paths = [_][]const u8{
        "/usr/local/bin/zls",
        "/usr/bin/zls",
    };
    for (&common_paths) |path| {
        if (compat.accessAbsolute(path, allocator)) {
            return allocator.dupe(u8, path);
        }
    }

    // Check home-relative paths
    const home: ?[]const u8 = if (environ_map) |em| em.get("HOME") else null;
    if (home) |h| {
        const home_bin = std.fs.path.join(allocator, &.{ h, "bin", "zls" }) catch return error.ZlsNotFound;
        defer allocator.free(home_bin);
        if (compat.accessAbsolute(home_bin, allocator)) {
            return allocator.dupe(u8, home_bin);
        }
    }

    return error.ZlsNotFound;
}
