const std = @import("std");
const builtin = @import("builtin");

/// Simple blocking mutex without an Io parameter.
/// In Zig 0.16.0, std.Thread.Mutex was removed and std.Io.Mutex
/// requires an Io parameter for lock/unlock. This wrapper provides
/// the old blocking lock/unlock API without requiring Io.
/// POSIX: pthread_mutex_t. Windows: SRWLOCK (no libc needed).
pub const PosixMutex = if (builtin.os.tag == .windows) WindowsMutex else PthreadMutex;

const PthreadMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PthreadMutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *PthreadMutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

const WindowsMutex = struct {
    inner: ?*anyopaque = null, // SRWLOCK_INIT

    extern "kernel32" fn AcquireSRWLockExclusive(lock: *?*anyopaque) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(lock: *?*anyopaque) callconv(.winapi) void;

    pub fn lock(self: *WindowsMutex) void {
        AcquireSRWLockExclusive(&self.inner);
    }

    pub fn unlock(self: *WindowsMutex) void {
        ReleaseSRWLockExclusive(&self.inner);
    }
};
