const std = @import("std");

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

        var child = try std.process.spawn(self.io, .{
            .argv = &.{self.zls_path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        _ = &child;
        self.child = child;
    }

    /// Get the stdin pipe for writing to ZLS.
    pub fn getStdin(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stdin;
    }

    /// Get the stdout pipe for reading from ZLS.
    pub fn getStdout(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stdout;
    }

    /// Get the stderr pipe for reading ZLS stderr.
    pub fn getStderr(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stderr;
    }

    /// Check if ZLS is currently alive.
    pub fn isAlive(self: *ZlsProcess) bool {
        return self.child != null;
    }

    /// Kill the ZLS child process.
    pub fn kill(self: *ZlsProcess) void {
        if (self.child) |*child| {
            child.kill(self.io);
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

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

test "ZlsProcess init state" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/usr/bin/zls");
    defer proc.deinit();
    try std.testing.expect(!proc.isAlive());
    try std.testing.expect(proc.getStdin() == null);
    try std.testing.expect(proc.getStdout() == null);
    try std.testing.expect(proc.getStderr() == null);
    try std.testing.expectEqual(@as(u32, 0), proc.restart_count);
}

test "ZlsProcess detachPipes on null child" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/usr/bin/zls");
    proc.detachPipes(); // should not crash
    try std.testing.expect(!proc.isAlive());
}

test "ZlsProcess kill on null child" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/usr/bin/zls");
    proc.kill(); // should not crash
    try std.testing.expect(!proc.isAlive());
}

test "ZlsProcess max restart count logic" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var proc = ZlsProcess.init(alloc, io, "/workspace", "/nonexistent-zls-binary");
    defer proc.deinit();
    proc.max_restarts = 3;

    // Simulate restart count reaching max (without actually spawning)
    proc.restart_count = 3;

    // Should return false (max exceeded) without attempting spawn
    const can_restart = proc.restart() catch false;
    try std.testing.expect(!can_restart);
    try std.testing.expectEqual(@as(u32, 3), proc.restart_count);
}

/// Find ZLS binary. Checks: explicit path, PATH lookup, common locations.
pub fn findZls(allocator: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ![]const u8 {
    // Try PATH first
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "which", "zls" },
    });
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
    } else |_| {}

    // Common locations
    const common_paths = [_][]const u8{
        "/usr/local/bin/zls",
        "/usr/bin/zls",
    };
    for (&common_paths) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return allocator.dupe(u8, path);
    }

    // Check home-relative paths
    if (environ) |env_map| {
        if (env_map.get("HOME")) |home| {
            const home_bin = std.fs.path.join(allocator, &.{ home, "bin", "zls" }) catch return error.ZlsNotFound;
            defer allocator.free(home_bin);
            std.Io.Dir.accessAbsolute(io, home_bin, .{}) catch return error.ZlsNotFound;
            return allocator.dupe(u8, home_bin);
        }
    }

    return error.ZlsNotFound;
}
