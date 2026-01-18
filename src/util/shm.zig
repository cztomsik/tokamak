const std = @import("std");

const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
});

/// Cross-process mutex which works reliably on Linux/macOS even after crash
pub const Mutex = struct {
    fd: std.fs.File,

    // TODO: This is Nth attempt, and it still doesn't feel right, files have
    // their own issues and maybe ShmQueue should be lockless anyway?
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
        self.fd.lock(.exclusive) catch @panic("TODO");
    }

    pub fn unlock(self: *Mutex) void {
        self.fd.unlock();
    }
};

pub const Shm = struct {
    name: [:0]const u8,
    fd: std.fs.File,
    data: []align(std.heap.page_size_min) u8,
    created: bool,

    // TODO: name could be runtime but then we should probably inline it in the
    // mmapped area, and maybe also add lock, refcounting, and IDK what else...
    // so maybe let's stick with comptime for now
    pub fn open(comptime name: [:0]const u8, size: usize) !Shm {
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
            .name = name,
            .fd = fd,
            .data = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd.handle, 0),
            .created = created,
        };
    }

    pub fn deinit(self: *Shm) void {
        std.posix.munmap(self.data);
        if (self.created) self.unlink();
        self.fd.close();
    }

    pub fn unlink(self: *Shm) void {
        _ = c.shm_unlink(self.name.ptr);
    }
};

test {
    var shm = try Shm.open("/test123", std.heap.page_size_min);
    defer shm.deinit();

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, shm.data[0..3]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        @memcpy(shm.data[0..3], "abc");
        std.process.exit(0);
    }

    _ = std.posix.waitpid(pid, 0);
    try std.testing.expectEqualStrings("abc", shm.data[0..3]);
}
