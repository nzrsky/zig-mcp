const std = @import("std");

/// Check if zvm is available.
pub fn isAvailable() bool {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "zvm", "--version" },
    });
    if (result) |r| {
        std.heap.page_allocator.free(r.stdout);
        std.heap.page_allocator.free(r.stderr);
        return r.term == .Exited and r.term.Exited == 0;
    } else |_| {
        return false;
    }
}
