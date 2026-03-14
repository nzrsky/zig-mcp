//! Compatibility layer for Zig 0.16 I/O migration.
//! Provides simple blocking read/write/close/pipe on POSIX using
//! posix/linux syscalls, bridging the gap between the old std.fs.File API
//! and the new std.Io-based API without requiring an Io context everywhere.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// A file handle wrapper compatible with std.Io.File that provides
/// blocking read/write/close methods without requiring Io.
pub const File = struct {
    handle: posix.fd_t,

    pub fn stdin() File {
        return .{ .handle = posix.STDIN_FILENO };
    }

    pub fn stdout() File {
        return .{ .handle = posix.STDOUT_FILENO };
    }

    pub fn stderr() File {
        return .{ .handle = posix.STDERR_FILENO };
    }

    /// Read from the file descriptor. Returns number of bytes read, or 0 on EOF.
    pub fn read(self: File, buf: []u8) !usize {
        return posix.read(self.handle, buf);
    }

    /// Write all bytes to the file descriptor.
    pub fn writeAll(self: File, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const rc = linux.write(self.handle, data[written..].ptr, data[written..].len);
            const err = posix.errno(rc);
            switch (err) {
                .SUCCESS => {
                    written += @intCast(rc);
                },
                .INTR => continue,
                .PIPE => return error.BrokenPipe,
                .AGAIN => return error.WouldBlock,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .FBIG => return error.FileTooBig,
                .PERM => return error.AccessDenied,
                else => return error.Unexpected,
            }
        }
    }

    /// Close the file descriptor.
    pub fn close(self: File) void {
        _ = linux.close(self.handle);
    }

    /// Convert to std.Io.File (for APIs that require it).
    pub fn toIoFile(self: File) std.Io.File {
        return .{ .handle = self.handle, .flags = .{ .nonblocking = false } };
    }

    /// Convert from std.Io.File.
    pub fn fromIoFile(f: std.Io.File) File {
        return .{ .handle = f.handle };
    }
};

/// Create a pipe, returning read_end and write_end as File structs.
pub fn pipe() !struct { read_end: File, write_end: File } {
    var fds: [2]i32 = undefined;
    const rc = linux.pipe(&fds);
    const err = posix.errno(rc);
    if (err != .SUCCESS) return error.Unexpected;
    return .{
        .read_end = .{ .handle = fds[0] },
        .write_end = .{ .handle = fds[1] },
    };
}

/// Check if a file exists at the given absolute path using faccessat syscall.
pub fn accessAbsolute(path_slice: []const u8, allocator: std.mem.Allocator) bool {
    // We need a null-terminated path for the syscall
    const path_z = allocator.dupeZ(u8, path_slice) catch return false;
    defer allocator.free(path_z);
    const rc = linux.faccessat(linux.AT.FDCWD, path_z, linux.F_OK, 0);
    return posix.errno(rc) == .SUCCESS;
}

/// Read entire file content from an absolute path.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = blk: {
        const rc = linux.openat(linux.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
        const err = posix.errno(rc);
        if (err != .SUCCESS) return error.FileNotFound;
        break :blk @as(posix.fd_t, @intCast(rc));
    };
    defer _ = linux.close(fd);

    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch return error.FileNotFound;
        if (n == 0) break;
        if (content.items.len + n > max_size) return error.StreamTooLong;
        try content.appendSlice(allocator, buf[0..n]);
    }

    return try content.toOwnedSlice(allocator);
}

/// Simple blocking mutex using Linux futex.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *Mutex) void {
        // Fast path: try to acquire immediately
        if (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        // Slow path: spin then futex wait
        while (true) {
            if (self.state.swap(2, .acquire) == 0) return;
            // Wait for state to change from 2
            _ = linux.futex_4arg(
                @ptrCast(&self.state.raw),
                .{ .private = true, .cmd = .WAIT },
                2,
                null,
            );
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.swap(0, .release) == 2) {
            // Wake one waiter
            _ = linux.futex_3arg(
                @ptrCast(&self.state.raw),
                .{ .private = true, .cmd = .WAKE },
                1,
            );
        }
    }
};

/// Simple event for thread synchronization using Linux futex.
pub const Event = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn set(self: *Event) void {
        self.state.store(1, .release);
        // Wake all waiters
        _ = linux.futex_3arg(
            @ptrCast(&self.state.raw),
            .{ .private = true, .cmd = .WAKE },
            @as(u32, std.math.maxInt(i32)),
        );
    }

    pub fn timedWait(self: *Event, timeout_ns: u64) !void {
        if (self.state.load(.acquire) == 1) return;
        const ts = linux.timespec{
            .sec = @intCast(timeout_ns / std.time.ns_per_s),
            .nsec = @intCast(timeout_ns % std.time.ns_per_s),
        };
        const rc = linux.futex_4arg(
            @ptrCast(&self.state.raw),
            .{ .private = true, .cmd = .WAIT },
            0,
            &ts,
        );
        if (self.state.load(.acquire) == 1) return;
        const err = posix.errno(rc);
        if (err == .TIMEDOUT) return error.TimedOut;
    }
};
