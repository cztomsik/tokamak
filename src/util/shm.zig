const std = @import("std");

const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
});

/// Cross-process mutex which works reliably on Linux/macOS even after crash.
/// Also thread-safe within a single process via std.Thread.Mutex.
pub const Mutex = struct {
    fd: std.fs.File,
    thread_mutex: std.Thread.Mutex = .{},

    pub fn init(name: [:0]const u8) !Mutex {
        var buf: [256]u8 = undefined;
        const tmp_path = try std.fmt.bufPrintZ(&buf, "/tmp/{s}.lock", .{std.mem.trimLeft(u8, name, "/")});

        return .{
            .fd = try std.fs.createFileAbsoluteZ(tmp_path, .{ .read = true }),
        };
    }

    pub fn deinit(self: *Mutex) void {
        self.fd.close();
    }

    pub fn lock(self: *Mutex) void {
        // Thread mutex first (same-process threads)
        self.thread_mutex.lock();

        // Then flock() for cross-process (this should never fail and there's little we can do so we panic)
        self.fd.lock(.exclusive) catch {
            self.thread_mutex.unlock();
            @panic("flock() failed");
        };
    }

    pub fn unlock(self: *Mutex) void {
        self.fd.unlock();
        self.thread_mutex.unlock();
    }
};

pub const Shm = struct {
    fd: std.fs.File,
    data: []align(std.heap.page_size_min) u8,
    created: bool,

    /// Opens or creates a shared memory segment. The `size` must be page-aligned.
    /// Returns with `created = true` if this call created the segment (caller
    /// should initialize it), or `created = false` if it already existed.
    pub fn open(name: [:0]const u8, size: usize) !Shm {
        std.debug.assert(size % std.heap.page_size_min == 0);

        var fd: std.fs.File = .{ .handle = c.shm_open(name, c.O_RDWR | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o666)) };
        const created: bool = fd.handle != -1;
        if (!created) fd.handle = c.shm_open(name, c.O_RDWR, @as(c.mode_t, 0o666));

        if (fd.handle == -1) {
            return error.ShmOpenFailed;
        }

        errdefer {
            if (created) _ = c.shm_unlink(name);
            fd.close();
        }

        if (created) {
            try fd.setEndPos(size);
        } else {
            const st = try fd.stat();
            if (st.size != @as(u64, @intCast(size))) return error.InvalidSize;
        }

        return .{
            .fd = fd,
            .data = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd.handle, 0),
            .created = created,
        };
    }

    /// Unmaps and closes the shared memory segment.
    ///
    /// NOTE: This does NOT unlink the segment - it persists in the system until
    /// explicitly unlinked via `Shm.unlink()` or until system reboot. This is
    /// intentional: it allows other processes to continue using the segment and
    /// preserves data across process restarts.
    pub fn deinit(self: *Shm) void {
        std.posix.munmap(self.data);
        self.fd.close();
    }

    pub fn unlink(name: [:0]const u8) void {
        _ = c.shm_unlink(name.ptr);
    }
};

test {
    var shm = try Shm.open("/test123", std.heap.page_size_min);
    defer shm.deinit();
    defer Shm.unlink("/test123");

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, shm.data[0..3]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        @memcpy(shm.data[0..3], "abc");
        std.process.exit(0);
    }

    _ = std.posix.waitpid(pid, 0);
    try std.testing.expectEqualStrings("abc", shm.data[0..3]);
}
