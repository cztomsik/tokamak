const std = @import("std");
const util = @import("util.zig");
const testing = @import("testing.zig");

pub const JobId = u64; // enum(u64) { _ }; https://github.com/ziglang/zig/issues/18462#issuecomment-1937095524

pub const JobInfo = struct {
    id: ?JobId = null,
    name: []const u8,
    key: ?[]const u8,
    data: []const u8,
    scheduled_at: ?i64,
    started_at: ?i64,
};

pub const JobOptions = struct {
    /// Optional key for deduplication.
    key: ?[]const u8 = null,
    /// Optional timestamp to schedule the job.
    schedule_at: ?i64 = null,
};

pub const Queue = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        findJob: *const fn (*Queue, std.mem.Allocator, JobId) anyerror!?JobInfo,
        listJobs: *const fn (*Queue, std.mem.Allocator) anyerror![]const JobInfo,
        submit: *const fn (*Queue, JobInfo) anyerror!?JobId,
        startNext: *const fn (*Queue) anyerror!?JobId,
        removeJob: *const fn (*Queue, JobId) anyerror!void,
        clear: *const fn (*Queue) anyerror!void,
    };

    pub fn push(self: *Queue, name: []const u8, data: []const u8, options: JobOptions) !void {
        _ = try self.submit(name, data, options);
    }

    pub fn submit(self: *Queue, name: []const u8, data: []const u8, options: JobOptions) !?JobId {
        // NOTE: This is only transient struct and the backend MUST copy whatever it needs
        return self.vtable.submit(self, .{
            .id = null,
            .name = name,
            .key = options.key,
            .data = data,
            .scheduled_at = options.schedule_at,
            .started_at = null,
        });
    }

    pub fn findJob(self: *Queue, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        return self.vtable.findJob(self, arena, id);
    }

    pub fn listJobs(self: *Queue, arena: std.mem.Allocator) ![]const JobInfo {
        return self.vtable.listJobs(self, arena);
    }

    pub fn startNext(self: *Queue) !?JobId {
        return self.vtable.startNext(self);
    }

    pub fn removeJob(self: *Queue, id: JobId) !void {
        return self.vtable.removeJob(self, id);
    }

    pub fn clear(self: *Queue) !void {
        return self.vtable.clear(self);
    }
};

pub const ShmQueue = struct {
    interface: Queue = .{
        .vtable = &.{
            .findJob = findJob,
            .listJobs = listJobs,
            .submit = submit,
            .startNext = startNext,
            .removeJob = removeJob,
            .clear = clear,
        },
    },
    time: *const fn () i64 = std.time.timestamp,
    mutex: util.ShmMutex,
    shm: util.Shm, // [...slotmap pages]
    jobs: util.SlotMap(Node),

    const Node = struct {
        name_end: u8,
        key_end: u8,
        data_end: u8,
        scheduled_at: ?i64,
        started_at: ?i64 = null,
        buf: [64]u8 = undefined,

        fn init(self: *Node, job: JobInfo) error{Overflow}!void {
            const key_len = if (job.key) |k| k.len else 0;
            const total_len = job.name.len + key_len + job.data.len;
            if (total_len > 64) return error.Overflow;

            self.* = .{
                .name_end = @intCast(job.name.len),
                .key_end = @intCast(job.name.len + key_len),
                .data_end = @intCast(total_len),
                .scheduled_at = job.scheduled_at,
            };

            @memcpy(self.buf[0..self.name_end], job.name);
            if (job.key) |k| @memcpy(self.buf[self.name_end..self.key_end], k);
            @memcpy(self.buf[self.key_end..self.data_end], job.data);
        }

        fn toJobInfo(self: *const Node, id: JobId, arena: std.mem.Allocator) !JobInfo {
            return .{
                .id = id,
                .name = try arena.dupe(u8, self.buf[0..self.name_end]),
                .key = if (self.name_end == self.key_end) null else try arena.dupe(u8, self.buf[self.name_end..self.key_end]),
                .data = try arena.dupe(u8, self.buf[self.key_end..self.data_end]),
                .scheduled_at = self.scheduled_at,
                .started_at = self.started_at,
            };
        }
    };

    pub fn init() !ShmQueue {
        const Page = util.SlotMap(Node).Page;
        // TODO: config
        const N_PAGES = 2;
        const size = std.mem.alignForward(usize, N_PAGES * @sizeOf(Page), std.heap.page_size_min);
        const shm = try util.Shm.open("/tk_queue", size);

        var self: ShmQueue = .{
            .shm = shm,
            .mutex = try util.ShmMutex.init(shm.name),
            .jobs = .{ .pages = @as([*]Page, @ptrCast(@alignCast(shm.data.ptr)))[0..N_PAGES] },
        };

        if (shm.created) {
            self.jobs = .init(self.jobs.pages);
        }

        return self;
    }

    pub fn deinit(self: *ShmQueue) void {
        self.mutex.deinit();
        self.shm.deinit();
    }

    fn submit(queue: *Queue, job: JobInfo) !?JobId {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check for duplicate key via linear scan
        if (job.key) |new_key| {
            var it = self.jobs.iter();
            while (it.next()) |entry| {
                const node = entry.value;
                if (node.name_end != node.key_end and std.mem.eql(u8, node.buf[node.name_end..node.key_end], new_key)) {
                    return null;
                }
            }
        }

        const entry = try self.jobs.insertEntry();
        try entry.value.init(job);
        return @bitCast(entry.id);
    }

    fn findJob(queue: *Queue, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.find(@bitCast(id))) |node| {
            return try node.toJobInfo(id, arena);
        }
        return null;
    }

    fn listJobs(queue: *Queue, arena: std.mem.Allocator) ![]const JobInfo {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        const res = try arena.alloc(JobInfo, self.jobs.len());
        var it = self.jobs.iter();
        for (res) |*slot| {
            const entry = it.next().?;
            slot.* = try entry.value.toJobInfo(@bitCast(entry.id), arena);
        }

        return res;
    }

    fn startNext(queue: *Queue) !?JobId {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = self.time();
        var best_id: ?JobId = null;
        var best_time: i64 = std.math.maxInt(i64);

        var it = self.jobs.iter();
        while (it.next()) |entry| {
            const node = entry.value;
            const scheduled = node.scheduled_at orelse std.math.minInt(i64);
            // Find earliest unstarted job that's ready
            if (node.started_at == null and scheduled <= now and scheduled < best_time) {
                best_time = scheduled;
                best_id = @bitCast(entry.id);
            }
        }

        if (best_id) |id| {
            if (self.jobs.find(@bitCast(id))) |node| {
                node.started_at = now;
            }
        }
        return best_id;
    }

    fn removeJob(queue: *Queue, id: JobId) !void {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.jobs.remove(@bitCast(id));
    }

    fn clear(queue: *Queue) !void {
        const self: *ShmQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.jobs.reset();
    }
};

fn expectJobs(q: *Queue, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectTable(try q.listJobs(arena.allocator()), expected);
}

test Queue {
    var mem_queue = try ShmQueue.init();
    defer mem_queue.deinit();

    const queue = &mem_queue.interface;

    testing.time.value = 0;
    mem_queue.time = &testing.time.get;

    // Enqueue
    const id1 = try queue.submit("job1", "123", .{}) orelse unreachable;
    const id2 = try queue.submit("job2", "bar", .{ .key = "foo" }) orelse unreachable;
    const id3 = try queue.submit("job3", "", .{ .schedule_at = 60 }) orelse unreachable;
    try queue.push("job2", "xxx", .{ .key = "foo" });

    try expectJobs(queue,
        \\| name | key | data | scheduled_at | started_at |
        \\|------|-----|------|--------------|------------|
        \\| job1 |     | 123  |              |            |
        \\| job2 | foo | bar  |              |            |
        \\| job3 |     |      | 60           |            |
    );

    // Start first
    const next1 = (try queue.startNext()).?;
    try std.testing.expectEqual(id1, next1);

    try expectJobs(queue,
        \\| name | key | data | started_at |
        \\|------|-----|------|------------|
        \\| job1 |     | 123  | 0          |
        \\| job2 | foo | bar  |            |
        \\| job3 |     |      |            |
    );

    // Remove first
    try queue.removeJob(id1);

    try expectJobs(queue,
        \\| name | key | data | started_at |
        \\|------|-----|------|------------|
        \\| job2 | foo | bar  |            |
        \\| job3 |     |      |            |
    );

    // Start second
    const next2 = (try queue.startNext()).?;
    try std.testing.expectEqual(id2, next2);

    try expectJobs(queue,
        \\| name | key | data | started_at |
        \\|------|-----|------|------------|
        \\| job2 | foo | bar  | 0          |
        \\| job3 |     |      |            |
    );

    // Remove second
    try queue.removeJob(id2);

    try expectJobs(queue,
        \\| name | key | data | started_at |
        \\|------|-----|------|------------|
        \\| job3 |     |      |            |
    );

    // No more jobs for now
    try std.testing.expectEqual(null, try queue.startNext());

    // Fast-forward to when third should be available
    testing.time.value += 120;

    // Start scheduled
    const next3 = (try queue.startNext()).?;
    try std.testing.expectEqual(id3, next3);

    // No more jobs available
    try std.testing.expectEqual(null, try queue.startNext());

    // Add more
    try queue.push("test", "1", .{});
    try queue.push("test", "2", .{});
    try queue.push("other", "3", .{});

    // Check listing
    try expectJobs(queue,
        \\| name  | data | started_at |
        \\|-------|------|------------|
        \\| test  | 1    |            |
        \\| test  | 2    |            |
        \\| job3  |      | 120        |
        \\| other | 3    |            |
    );

    // Test findJob
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job3 = try queue.findJob(arena.allocator(), id3);
    try testing.expectEqual(job3.?.id, id3);
    try testing.expectEqual(try queue.findJob(arena.allocator(), 999999), null);
}
