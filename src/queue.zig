const std = @import("std");
const meta = @import("meta.zig");
const util = @import("util.zig");
const testing = @import("testing.zig");

pub const JobId = u64; // enum(u64) { _ }; https://github.com/ziglang/zig/issues/18462#issuecomment-1937095524

pub const JobState = enum {
    pending,
    running,
    completed,
    failed,
};

pub const JobInfo = struct {
    id: ?JobId = null,
    name: []const u8,
    key: ?[]const u8,
    data: []const u8,
    state: JobState,
    result: ?[]const u8,
    @"error": ?[]const u8,
    attempts: u32,
    max_attempts: u32,
    created_at: i64,
    scheduled_at: ?i64,
    started_at: ?i64,
    completed_at: ?i64,
};

pub const JobOptions = struct {
    /// Optional key for deduplication.
    key: ?[]const u8 = null,
    /// Maximum number of attempts allowed.
    max_attempts: u32 = 1,
    /// Optional timestamp to schedule the job.
    schedule_at: ?i64 = null,
};

pub const Queue = struct {
    pub const VTable = struct {
        enqueueJob: *const fn (*Queue, JobInfo) anyerror!?JobId,
        getJobInfo: *const fn (*Queue, std.mem.Allocator, JobId) anyerror!?JobInfo,
        getAllJobs: *const fn (*Queue, std.mem.Allocator) anyerror![]JobInfo,
        startNext: *const fn (*Queue, i64) anyerror!?JobId,
        startJob: *const fn (*Queue, JobId) anyerror!bool,
        retryJob: *const fn (*Queue, JobId) anyerror!void,
        removeJob: *const fn (*Queue, JobId) anyerror!void,
        handleResult: *const fn (*Queue, JobId, anyerror![]const u8, i64) anyerror!void,
    };

    vtable: *const VTable,
    time: *const fn () i64 = std.time.timestamp,

    pub fn enqueue(self: *Queue, name: []const u8, data: anytype, options: JobOptions) !?JobId {
        // We only stringify small payloads
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const data_str: []const u8 = if (comptime meta.isString(@TypeOf(data))) data else blk: {
            try std.json.stringify(data, .{}, fbs.writer());
            break :blk fbs.getWritten();
        };

        // NOTE: This is only transient struct and the backend MUST copy whatever it needs
        const job: JobInfo = .{
            .id = null,
            .name = name,
            .key = options.key,
            .attempts = 0,
            .max_attempts = options.max_attempts,
            .data = data_str,
            .state = .pending,
            .result = null,
            .@"error" = null,
            .created_at = std.time.timestamp(),
            .scheduled_at = options.schedule_at,
            .started_at = null,
            .completed_at = null,
        };

        return self.vtable.enqueueJob(self, job);
    }

    pub fn getJobInfo(self: *Queue, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        return self.vtable.getJobInfo(self, arena, id);
    }

    pub fn getAllJobs(self: *Queue, arena: std.mem.Allocator) ![]JobInfo {
        return self.vtable.getAllJobs(self, arena);
    }

    pub fn startNext(self: *Queue) !?JobId {
        return self.vtable.startNext(self, self.time());
    }

    pub fn startJob(self: *Queue, id: JobId) !bool {
        return self.vtable.startJob(self, id);
    }

    pub fn retryJob(self: *Queue, id: JobId) !void {
        return self.vtable.retryJob(self, id);
    }

    pub fn removeJob(self: *Queue, id: JobId) !void {
        return self.vtable.removeJob(self, id);
    }

    pub fn handleSuccess(self: *Queue, id: JobId, res: anytype) !void {
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const result_str: []const u8 = switch (@TypeOf(res)) {
            void => "",
            else => blk: {
                try std.json.stringify(res, .{}, fbs.writer());
                break :blk fbs.getWritten();
            },
        };
        return self.vtable.handleResult(self, id, result_str, self.time());
    }

    pub fn handleFailure(self: *Queue, id: JobId, err: anyerror) !void {
        return self.vtable.handleResult(self, id, err, self.time());
    }
};

pub const MemQueue = struct {
    interface: Queue,
    mutex: std.Thread.Mutex.Recursive = .init,
    allocator: std.mem.Allocator,
    jobs: util.SlotMap(JobInfo),
    upcoming: std.PriorityQueue(Schedule, void, cmpSchedule),
    keys: std.StringHashMapUnmanaged(JobId),

    const Schedule = struct {
        id: JobId,
        scheduled_at: ?i64,
    };

    pub fn init(allocator: std.mem.Allocator) !MemQueue {
        return .{
            .interface = .{
                .vtable = &.{
                    .enqueueJob = &enqueueJob,
                    .getJobInfo = &getJobInfo,
                    .getAllJobs = &getAllJobs,
                    .startNext = &startNext,
                    .startJob = &startJob,
                    .retryJob = &retryJob,
                    .removeJob = &removeJob,
                    .handleResult = &handleResult,
                },
            },

            .allocator = allocator,
            .jobs = try .initAlloc(allocator, 4),
            .upcoming = .init(allocator, {}),
            .keys = .empty,
        };
    }

    pub fn deinit(self: *MemQueue) void {
        self.mutex.lock();
        // defer self.mutex.unlock();

        const allocator = self.allocator;

        var it = self.jobs.iter();
        while (it.next()) |entry| {
            meta.free(allocator, entry.value.*);
        }

        self.jobs.deinit(allocator);
        self.upcoming.deinit();
        self.keys.deinit(allocator);
    }

    fn enqueueJob(queue: *Queue, job: JobInfo) !?JobId {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (job.key) |key| {
            if (self.keys.get(key)) |id| {
                if (self.jobs.find(@bitCast(id))) |existing| {
                    if (existing.state == .pending) {
                        // Update job (but copy the data)
                        const old_data = existing.data;
                        existing.data = try self.allocator.dupe(u8, job.data);
                        existing.scheduled_at = job.scheduled_at;
                        self.allocator.free(old_data);

                        return null;
                    }
                }
            } else {
                // Let's make a space first so we don't need to worry about errdefer
                try self.keys.ensureUnusedCapacity(self.allocator, 1);
            }
        }

        // No key specified, proceed normally
        const copy = try meta.dupe(self.allocator, job);
        errdefer meta.free(self.allocator, copy);

        const id: JobId = @bitCast(try self.jobs.insert(copy));
        errdefer self.jobs.remove(@bitCast(id));

        if (copy.key) |key_copy| {
            // Now we can save the key (which we own)
            self.keys.putAssumeCapacity(key_copy, id);
        }

        try self.upcoming.add(.{
            .id = id,
            .scheduled_at = job.scheduled_at,
        });

        return id;
    }

    fn getJobInfo(queue: *Queue, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.find(@bitCast(id)) orelse {
            return error.JobNotFound; // try self.getJob?
        };

        var copy = try meta.dupe(arena, job.*);
        copy.id = @bitCast(job.id.?);

        return copy;
    }

    fn getAllJobs(queue: *Queue, arena: std.mem.Allocator) ![]JobInfo {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        var res = std.ArrayList(JobInfo).init(arena);

        var it = self.jobs.iter();
        while (it.next()) |entry| {
            var copy = try meta.dupe(arena, entry.value.*);
            copy.id = @bitCast(entry.id);
            try res.append(copy);
        }

        return res.toOwnedSlice();
    }

    fn startNext(queue: *Queue, time: i64) !?JobId {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.upcoming.peek()) |sched| {
            if (sched.scheduled_at == null or sched.scheduled_at.? <= time) {
                _ = self.upcoming.remove();

                if (self.jobs.find(@bitCast(sched.id))) |job| {
                    if (job.state == .pending) {
                        job.state = .running;
                        job.started_at = time;
                        job.attempts += 1;
                        return sched.id;
                    }
                }
            } else {
                // No work
                break;
            }
        }

        return null;
    }

    fn startJob(queue: *Queue, id: JobId) !bool {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.find(@bitCast(id)) orelse {
            return error.JobNotFound; // try self.getJob?
        };

        if (job.state == .pending) {
            job.state = .running;
            job.started_at = std.time.timestamp();
            job.attempts += 1;
            return true;
        } else {
            return false;
        }
    }

    fn retryJob(queue: *Queue, id: JobId) !void {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.find(@bitCast(id))) |job| {
            job.max_attempts = @min(job.max_attempts, job.attempts + 1);
            job.state = .pending;
        } else return error.JobNotFound;
    }

    fn removeJob(queue: *Queue, id: JobId) !void {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.find(@bitCast(id))) |job| {
            if (job.key) |key| {
                _ = self.keys.remove(key);
            }
        }

        self.jobs.remove(@bitCast(id));
    }

    fn handleResult(queue: *Queue, id: JobId, result: anyerror![]const u8, time: i64) !void {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.find(@bitCast(id)) orelse {
            return error.JobNotFound;
        };

        if (result) |res| {
            const new_result = try self.allocator.dupe(u8, res);
            errdefer self.allocator.free(new_result);

            // Free old
            if (job.result) |old| {
                self.allocator.free(old);
            }

            job.state = .completed;
            job.result = new_result;
            job.@"error" = null;
            job.completed_at = time;
        } else |err| {
            // NOTE: @errorName is static lifetime so we don't need to free old job.error
            //       BUT we are using meta.free() in deinit() and we MIGHT want to do save/load one day
            const new_error = try self.allocator.dupe(u8, @errorName(err));
            errdefer self.allocator.free(new_error);

            // Free old
            if (job.@"error") |old_error| {
                self.allocator.free(old_error);
            }

            if (job.attempts >= job.max_attempts) {
                job.state = .failed;
                job.@"error" = new_error;
                job.completed_at = time;
            } else {
                job.state = .pending;
                job.@"error" = new_error;
                job.scheduled_at = time + std.math.pow(i64, 2, job.attempts) * 60; // exponential backoff

                // Re-submit
                try self.upcoming.add(.{
                    .id = id,
                    .scheduled_at = job.scheduled_at,
                });
            }
        }
    }

    fn cmpSchedule(_: void, a: Schedule, b: Schedule) std.math.Order {
        return std.math.order(a.scheduled_at orelse 0, b.scheduled_at orelse 0);
    }
};

test Queue {
    var mem_queue = try MemQueue.init(testing.allocator);
    defer mem_queue.deinit();

    const queue = &mem_queue.interface;

    testing.time.value = 0;
    queue.time = &testing.time.get;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Enqueue
    const id1 = (try queue.enqueue("job1", 123, .{})).?;
    const id2 = (try queue.enqueue("job2", "foo", .{ .key = "foo", .max_attempts = 2 })).?;
    _ = try queue.enqueue("job2", "bar", .{ .key = "foo" });

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | data | state   | attempts |
        \\|------|-----|------|---------|----------|
        \\| job1 |     | 123  | pending | 0        |
        \\| job2 | foo | bar  | pending | 0        |
    );

    // Start first
    const next1 = (try queue.startNext()).?;
    try std.testing.expectEqual(id1, next1);

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | data | state   | attempts |
        \\|------|-----|------|---------|----------|
        \\| job1 |     | 123  | running | 1        |
        \\| job2 | foo | bar  | pending | 0        |
    );

    // Complete first
    try queue.handleSuccess(id1, "success");

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | data | state     | attempts | result    |
        \\|------|-----|------|-----------|----------|-----------|
        \\| job1 |     | 123  | completed | 1        | "success" |
        \\| job2 | foo | bar  | pending   | 0        |           |
    );

    // Start second
    const next2 = (try queue.startNext()).?;
    try std.testing.expectEqual(id2, next2);

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | data | state     | attempts | result    |
        \\|------|-----|------|-----------|----------|-----------|
        \\| job1 |     | 123  | completed | 1        | "success" |
        \\| job2 | foo | bar  | running   | 1        |           |
    );

    // Fail second
    try queue.handleFailure(id2, error.TestError);

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | data | state     | attempts | result    | error     |
        \\|------|-----|------|-----------|----------|-----------|-----------|
        \\| job1 |     | 123  | completed | 1        | "success" |           |
        \\| job2 | foo | bar  | pending   | 1        |           | TestError |
    );

    // No more jobs for now
    try std.testing.expectEqual(null, try queue.startNext());

    // Fast-forward to when retry should be available
    testing.time.value += 120;

    // Auto-restart second
    const next3 = (try queue.startNext()).?;
    try std.testing.expectEqual(id2, next3);

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | data | state     | attempts | result    | error     |
        \\|------|-----|------|-----------|----------|-----------|-----------|
        \\| job1 |     | 123  | completed | 1        | "success" |           |
        \\| job2 | foo | bar  | running   | 2        |           | TestError |
    );

    // Fail Second Again (should be final failure since max_attempts = 2)
    try queue.handleFailure(id2, error.AnotherError);

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | data | state     | attempts | result    | error        |
        \\|------|-----|------|-----------|----------|-----------|--------------|
        \\| job1 |     | 123  | completed | 1        | "success" |              |
        \\| job2 | foo | bar  | failed    | 2        |           | AnotherError |
    );

    // No more jobs available
    try std.testing.expectEqual(null, try queue.startNext());
}
