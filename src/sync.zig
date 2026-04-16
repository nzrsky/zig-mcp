const std = @import("std");

/// Simple mutex wrapper around POSIX pthread_mutex_t.
/// In Zig 0.16.0, std.Thread.Mutex was removed and std.Io.Mutex
/// requires an Io parameter for lock/unlock. This wrapper provides
/// the old blocking lock/unlock API without requiring Io.
pub const PosixMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PosixMutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *PosixMutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};
