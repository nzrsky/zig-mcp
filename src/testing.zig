// --- tests
//! Shared test-only helpers.

const std = @import("std");

/// The test runner's `Io`. Note that `std.Io` is a fat pointer into an
/// `Io.Threaded` instance, so an `Io` must never outlive the instance backing
/// it — deriving one from a local and returning it hands out a dangling
/// pointer. This one is owned by the runner and lives for the whole process.
pub fn io() std.Io {
    return std.testing.io;
}

/// A connected pipe pair. Both ends must be closed by the caller.
pub const Pipe = struct {
    read_end: std.Io.File,
    write_end: std.Io.File,

    pub fn open() !Pipe {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.SystemResources;
        return .{
            .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        };
    }
};

/// Read until EOF or `buf` is full.
pub fn readAll(file: std.Io.File, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(io(), &.{buf[total..]}) catch return buf[0..total];
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// A throwaway directory plus its absolute path, for code that resolves
/// workspace-relative paths.
pub const TmpWorkspace = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TmpWorkspace {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io(), &buf);
        return .{
            .tmp = tmp,
            .root = try allocator.dupe(u8, buf[0..len]),
            .allocator = allocator,
        };
    }

    pub fn writeFile(self: *TmpWorkspace, name: []const u8, contents: []const u8) !void {
        try self.tmp.dir.writeFile(io(), .{ .sub_path = name, .data = contents });
    }

    /// Absolute path of `name` inside the workspace. Caller frees.
    pub fn path(self: *TmpWorkspace, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, name });
    }

    pub fn deinit(self: *TmpWorkspace) void {
        self.allocator.free(self.root);
        self.tmp.cleanup();
    }
};
