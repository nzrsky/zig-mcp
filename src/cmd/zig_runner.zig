const std = @import("std");

/// Run a zig command and capture output.
pub fn runZig(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "zig");
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = 512 * 1024,
    });

    const exit_code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 1,
    };

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}
