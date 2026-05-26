const std = @import("std");
const c = @import("c");

/// Cross-process mutex which works reliably on Linux/macOS even after crash.
/// Also thread-safe within a single process via std.Io.Mutex.
pub const Mutex = struct {
    fd: std.Io.File,
    thread_mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, name: [:0]const u8) !Mutex {
        var buf: [256]u8 = undefined;
        const tmp_path = try std.fmt.bufPrintSentinel(
            &buf,
            "/tmp/{s}.lock",
            .{std.mem.trimStart(u8, name, "/")},
            0,
        );

        return .{
            .fd = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .read = true }),
        };
    }

    pub fn deinit(self: *Mutex, io: std.Io) void {
        self.fd.close(io);
    }

    pub fn lock(self: *Mutex, io: std.Io) void {
        // Thread mutex first (same-process threads)
        self.thread_mutex.lockUncancelable(io);

        // Then flock() for cross-process (this should never fail and there's little we can do so we panic)
        self.fd.lock(io, .exclusive) catch {
            self.thread_mutex.unlock(io);
            @panic("flock() failed");
        };
    }

    pub fn unlock(self: *Mutex, io: std.Io) void {
        self.fd.unlock(io);
        self.thread_mutex.unlock(io);
    }
};

pub const Shm = struct {
    fd: std.Io.File,
    data: []align(std.heap.page_size_min) u8,
    created: bool,

    /// Opens or creates a shared memory segment. The `size` must be page-aligned.
    /// Returns with `created = true` if this call created the segment (caller
    /// should initialize it), or `created = false` if it already existed.
    pub fn open(io: std.Io, name: [:0]const u8, size: usize) !Shm {
        std.debug.assert(size % std.heap.page_size_min == 0);

        var fd: std.Io.File = .{
            .handle = c.shm_open(name, c.O_RDWR | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o666)),
            .flags = .{ .nonblocking = false },
        };
        const created: bool = fd.handle != -1;
        if (!created) fd.handle = c.shm_open(name, c.O_RDWR, @as(c.mode_t, 0o666));

        if (fd.handle == -1) {
            return error.ShmOpenFailed;
        }

        errdefer {
            if (created) _ = c.shm_unlink(name);
            fd.close(io);
        }

        if (created) {
            try fd.setLength(io, size);
        } else {
            const st = try fd.stat(io);
            if (st.size != @as(u64, @intCast(size))) return error.InvalidSize;
        }

        return .{
            .fd = fd,
            .data = try std.posix.mmap(null, size, @as(std.posix.PROT, .{ .READ = true, .WRITE = true }), .{ .TYPE = .SHARED }, fd.handle, 0),
            .created = created,
        };
    }

    /// Unmaps and closes the shared memory segment.
    ///
    /// NOTE: This does NOT unlink the segment - it persists in the system until
    /// explicitly unlinked via `Shm.unlink()` or until system reboot. This is
    /// intentional: it allows other processes to continue using the segment and
    /// preserves data across process restarts.
    pub fn deinit(self: *Shm, io: std.Io) void {
        std.posix.munmap(self.data);
        self.fd.close(io);
    }

    pub fn unlink(name: [:0]const u8) void {
        _ = c.shm_unlink(name.ptr);
    }
};

test {
    var shm = try Shm.open(std.testing.io, "/test123", std.heap.page_size_min);
    defer {
        shm.deinit(std.testing.io);
        Shm.unlink("/test123");
    }

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, shm.data[0..3]);

    const pid = c.fork();
    if (pid == 0) {
        @memcpy(shm.data[0..3], "abc");
        std.process.exit(0);
    }

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expectEqualStrings("abc", shm.data[0..3]);
}
