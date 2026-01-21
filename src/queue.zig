const std = @import("std");
const util = @import("util.zig");
const testing = @import("testing.zig");

const Shm = util.Shm;
const ShmMutex = util.ShmMutex;

pub const JobId = u64;

pub const JobInfo = struct {
    id: ?JobId = null,
    name: []const u8,
    /// Empty string means no key (no deduplication).
    key: []const u8 = "",
    data: []const u8,
    scheduled_at: ?i64 = null,
};

pub const Stats = struct {
    enqueued: u64 = 0,
    dequeued: u64 = 0,
};

pub const Queue = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        enqueue: *const fn (*Queue, JobInfo) anyerror!?JobId,
        dequeue: *const fn (*Queue, std.mem.Allocator) anyerror!?JobInfo,
        remove: *const fn (*Queue, JobId) anyerror!void,
        clear: *const fn (*Queue) anyerror!void,
        len: *const fn (*Queue) anyerror!usize,
        stats: *const fn (*Queue) anyerror!Stats,
        list: *const fn (*Queue, std.mem.Allocator) anyerror![]JobInfo,
    };

    pub fn len(self: *Queue) !usize {
        return self.vtable.len(self);
    }

    pub fn enqueue(self: *Queue, job: JobInfo) !?JobId {
        return self.vtable.enqueue(self, job);
    }

    pub fn dequeue(self: *Queue, arena: std.mem.Allocator) !?JobInfo {
        return self.vtable.dequeue(self, arena);
    }

    pub fn remove(self: *Queue, id: JobId) !void {
        return self.vtable.remove(self, id);
    }

    pub fn clear(self: *Queue) !void {
        return self.vtable.clear(self);
    }

    pub fn list(self: *Queue, arena: std.mem.Allocator) ![]JobInfo {
        return self.vtable.list(self, arena);
    }

    pub fn stats(self: *Queue) !Stats {
        return self.vtable.stats(self);
    }
};

pub const ShmQueueConfig = struct {
    name: []const u8 = "tk_queue",
    capacity: u32 = 100,
};

/// A lightweight, crash-safe, at-most-once*, bounded job queue. Jobs can be
/// scheduled in the future and if they have a key, it will be used for avoiding
/// duplicates. There is no persistence guarantee but the queue will remain
/// consistent even if any process dies (or is killed) at any point. It is
/// implemented using POSIX shared memory for storage (macos/linux only) and
/// file locking for synchronization. No broker, no database, no worker thread.
///
/// *: At-most-once applies at the API boundary. If a process is killed before
/// `dequeue()` returns, the item will be retrieved again by another caller,
/// because it was never handed over for processing.
///
/// NOTE: Atomic operations are INTENTIONAL for crash-resilience, not for
/// lock-free access. The mutex serializes live processes, but if a process
/// crashes mid-operation, atomics with release/acquire semantics ensure other
/// processes see either a fully-written slot or FREE but NEVER partial state.
pub const ShmQueue = struct {
    mutex: ShmMutex,
    shm: Shm,
    time: *const fn () i64,
    header: *Header, // points to the SHM
    slots: []Slot, // points to the SHM
    interface: Queue,

    const Header = extern struct {
        magic: u32 = @bitCast("QUE".*),
        version: u32 = VERSION,
        next_id: std.atomic.Value(JobId) = .init(1),
        capacity: u32,
        stats: extern struct {
            enqueued: std.atomic.Value(u64) = .init(0),
            dequeued: std.atomic.Value(u64) = .init(0),
        } = .{},
        _: [24]u8 = undefined,
    };

    const Slot = struct {
        id: std.atomic.Value(JobId),
        scheduled_at: i64,
        name_end: u8,
        key_end: u8,
        data_end: u8,
        buf: [BUF_LEN]u8,
    };

    comptime {
        // Check sizes
        std.debug.assert(@sizeOf(Header) == 64);
        std.debug.assert(@sizeOf(Slot) == 256);

        // Ensure Slot array is properly aligned when placed after Header
        std.debug.assert(@sizeOf(Header) % @alignOf(Slot) == 0);
    }

    const VERSION: u32 = 1;
    const BUF_LEN = 237;
    const FREE: JobId = 0;

    /// Initialize the queue in place. The caller must ensure `self` is at a
    /// stable memory location that won't be moved after this call.
    pub fn init(self: *ShmQueue, config: ShmQueueConfig) !void {
        self.time = std.time.timestamp;
        self.interface = .{
            .vtable = &.{
                .len = len,
                .enqueue = enqueue,
                .dequeue = dequeue,
                .remove = remove,
                .clear = clear,
                .list = list,
                .stats = stats,
            },
        };

        var buf: [256]u8 = undefined;
        const shm_name = try std.fmt.bufPrintZ(
            &buf,
            "{s}_{d}_{d}",
            .{ config.name, VERSION, config.capacity },
        );

        self.mutex = try ShmMutex.init(shm_name);
        self.mutex.lock();
        defer self.mutex.unlock();

        self.shm = try Shm.open(shm_name, std.mem.alignForward(usize, @sizeOf(Header) + config.capacity * @sizeOf(Slot), std.heap.page_size_min));

        self.header = @ptrCast(@alignCast(self.shm.data.ptr));
        self.slots = @as([*]Slot, @ptrCast(@alignCast(self.shm.data.ptr[@sizeOf(Header)..])))[0..config.capacity];

        if (self.shm.created) {
            self.header.* = .{ .capacity = config.capacity };
            // NOTE: slots are already FREE because Shm guarantees zeroed memory
        } else {
            std.debug.assert(self.header.version == VERSION);
            std.debug.assert(self.header.capacity == config.capacity);
        }

        std.log.debug("ShmQueue {s} (init={})", .{ shm_name, @intFromBool(self.shm.created) });
    }

    pub fn deinit(self: *ShmQueue) void {
        self.mutex.deinit();
        self.shm.deinit();
    }

    fn len(queue: *Queue) !usize {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        var n: usize = 0;
        for (self.slots) |*s| {
            if (s.id.load(.acquire) != FREE) n += 1;
        }
        return n;
    }

    fn enqueue(queue: *Queue, job: JobInfo) !?JobId {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        const key_len = job.key.len;
        const total_len = job.name.len + key_len + job.data.len;
        if (total_len > BUF_LEN) return error.Overflow;

        // Optionally check for a duplicate key and skip
        if (job.key.len > 0) {
            for (self.slots) |*s| {
                if (s.id.load(.acquire) != FREE and std.mem.eql(u8, job.key, s.buf[s.name_end..s.key_end])) return null;
            }
        }

        // Find an empty slot
        for (self.slots) |*s| {
            if (s.id.load(.acquire) == FREE) {
                // Init contents first and THEN set id ATOMICALLY
                s.name_end = @intCast(job.name.len);
                s.key_end = @intCast(s.name_end + key_len);
                s.data_end = @intCast(total_len);
                s.scheduled_at = job.scheduled_at orelse self.time();
                @memcpy(s.buf[0..s.name_end], job.name);
                @memcpy(s.buf[s.name_end..s.key_end], job.key);
                @memcpy(s.buf[s.key_end..s.data_end], job.data);

                const id = self.header.next_id.fetchAdd(1, .seq_cst);
                s.id.store(id, .release);
                _ = self.header.stats.enqueued.fetchAdd(1, .release);

                return id;
            }
        }

        return error.Overflow;
    }

    fn dequeue(queue: *Queue, arena: std.mem.Allocator) !?JobInfo {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = self.time();
        var match: ?*Slot = null;

        for (self.slots) |*s| {
            if (s.id.load(.acquire) == FREE or s.scheduled_at > now) continue;
            if (match == null or s.scheduled_at < match.?.scheduled_at) match = s;
        }

        if (match) |s| {
            const data = try arena.alloc(u8, s.data_end);
            @memcpy(data, s.buf[0..s.data_end]);

            const copy: JobInfo = .{
                .id = s.id.load(.acquire),
                .scheduled_at = s.scheduled_at,
                .name = data[0..s.name_end],
                .key = data[s.name_end..s.key_end],
                .data = data[s.key_end..s.data_end],
            };

            s.id.store(FREE, .release);
            _ = self.header.stats.dequeued.fetchAdd(1, .release);

            return copy;
        }

        return null;
    }

    fn remove(queue: *Queue, id: JobId) !void {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.slots) |*s| {
            if (s.id.load(.acquire) == id) {
                s.id.store(FREE, .release);
                return;
            }
        }
    }

    fn clear(queue: *Queue) !void {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.slots) |*s| {
            s.id.store(FREE, .release);
        }
    }

    fn list(queue: *Queue, arena: std.mem.Allocator) ![]JobInfo {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        var jobs: std.ArrayList(JobInfo) = .{};

        for (self.slots) |*s| {
            const id = s.id.load(.acquire);
            if (id == FREE) continue;

            const data = try arena.alloc(u8, s.data_end);
            @memcpy(data, s.buf[0..s.data_end]);

            try jobs.append(arena, .{
                .id = id,
                .scheduled_at = s.scheduled_at,
                .name = data[0..s.name_end],
                .key = data[s.name_end..s.key_end],
                .data = data[s.key_end..s.data_end],
            });
        }

        return jobs.items;
    }

    fn stats(queue: *Queue) !Stats {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .enqueued = self.header.stats.enqueued.load(.acquire),
            .dequeued = self.header.stats.dequeued.load(.acquire),
        };
    }
};

fn expectJobs(q: *Queue, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectTable(try q.list(arena.allocator()), expected);
}

test Queue {
    var shm_queue: ShmQueue = undefined;
    try shm_queue.init(.{ .name = "test" });
    defer shm_queue.deinit();

    const queue = &shm_queue.interface;
    defer queue.clear() catch unreachable;

    testing.time.value = 0;
    shm_queue.time = &testing.time.get;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Enqueue
    const id1 = try queue.enqueue(.{ .name = "job1", .data = "123" }) orelse unreachable;
    const id2 = try queue.enqueue(.{ .name = "job2", .data = "bar", .key = "foo" }) orelse unreachable;
    const id3 = try queue.enqueue(.{ .name = "job3", .data = "", .scheduled_at = 60 }) orelse unreachable;
    _ = try queue.enqueue(.{ .name = "job2", .data = "xxx", .key = "foo" });

    try expectJobs(queue,
        \\| name | key | data | scheduled_at |
        \\|------|-----|------|--------------|
        \\| job1 |     | 123  | 0            |
        \\| job2 | foo | bar  | 0            |
        \\| job3 |     |      | 60           |
    );

    // Start first
    const next1 = (try queue.dequeue(arena.allocator())).?;
    try std.testing.expectEqual(id1, next1.id);

    try expectJobs(queue,
        \\| name | key | data |
        \\|------|-----|------|
        \\| job2 | foo | bar  |
        \\| job3 |     |      |
    );

    // Remove first
    try queue.remove(id1);

    try expectJobs(queue,
        \\| name | key | data |
        \\|------|-----|------|
        \\| job2 | foo | bar  |
        \\| job3 |     |      |
    );

    // Start second
    const next2 = (try queue.dequeue(arena.allocator())).?;
    try std.testing.expectEqual(id2, next2.id);

    try expectJobs(queue,
        \\| name | key | data |
        \\|------|-----|------|
        \\| job3 |     |      |
    );

    // Remove second
    try queue.remove(id2);

    try expectJobs(queue,
        \\| name | key | data |
        \\|------|-----|------|
        \\| job3 |     |      |
    );

    // No more jobs for now
    try std.testing.expectEqual(null, try queue.dequeue(arena.allocator()));

    // Fast-forward to when third should be available
    testing.time.value += 120;

    // Start scheduled
    const next3 = (try queue.dequeue(arena.allocator())).?;
    try std.testing.expectEqual(id3, next3.id);

    // No more jobs available
    try std.testing.expectEqual(null, try queue.dequeue(arena.allocator()));

    // Add more
    _ = try queue.enqueue(.{ .name = "test", .data = "1" });
    _ = try queue.enqueue(.{ .name = "test", .data = "2" });
    _ = try queue.enqueue(.{ .name = "other", .data = "3" });

    // Check listing
    try expectJobs(queue,
        \\| name  | data |
        \\|-------|------|
        \\| test  | 1    |
        \\| test  | 2    |
        \\| other | 3    |
    );

    // Print stats
    std.debug.print(
        "queue.len = {}, queue.stats = {any}\n",
        .{ try queue.len(), try queue.stats() },
    );
}
