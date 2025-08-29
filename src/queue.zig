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

pub const JobFilter = struct {
    name: ?[]const u8 = null,
    state: ?JobState = null,
    limit: u32 = 200,
};

pub const Command = union(enum) {
    submit: JobInfo,
    start_next: void,
    retry: JobId,
    remove: JobId,
    finish: struct {
        id: JobId,
        result: anyerror![]const u8,
    },
};

pub const Queue = struct {
    pub const VTable = struct {
        findJob: *const fn (*Queue, std.mem.Allocator, JobId) anyerror!?JobInfo,
        listJobs: *const fn (*Queue, std.mem.Allocator, JobFilter) anyerror![]const JobInfo,
        exec: *const fn (*Queue, Command) anyerror!?JobId,
    };

    vtable: *const VTable,
    time: *const fn () i64 = std.time.timestamp,

    pub fn push(self: *Queue, name: []const u8, data: []const u8, options: JobOptions) !void {
        _ = try self.submit(name, data, options);
    }

    pub fn submit(self: *Queue, name: []const u8, data: []const u8, options: JobOptions) !?JobId {
        // NOTE: This is only transient struct and the backend MUST copy whatever it needs
        const job: JobInfo = .{
            .id = null,
            .name = name,
            .key = options.key,
            .attempts = 0,
            .max_attempts = options.max_attempts,
            .data = data,
            .state = .pending,
            .result = null,
            .@"error" = null,
            .created_at = self.time(),
            .scheduled_at = options.schedule_at,
            .started_at = null,
            .completed_at = null,
        };

        return self.vtable.exec(self, .{ .submit = job });
    }

    pub fn findJob(self: *Queue, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        return self.vtable.findJob(self, arena, id);
    }

    pub fn listJobs(self: *Queue, arena: std.mem.Allocator, filter: JobFilter) ![]const JobInfo {
        return self.vtable.listJobs(self, arena, filter);
    }

    pub fn startNext(self: *Queue) !?JobId {
        return self.vtable.exec(self, .{ .start_next = {} });
    }

    pub fn retryJob(self: *Queue, id: JobId) !void {
        _ = try self.vtable.exec(self, .{ .retry = id });
    }

    pub fn removeJob(self: *Queue, id: JobId) !void {
        _ = try self.vtable.exec(self, .{ .remove = id });
    }

    pub fn finishJob(self: *Queue, id: JobId, res: anyerror![]const u8) !void {
        _ = try self.vtable.exec(self, .{ .finish = .{ .id = id, .result = res } });
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
                    .findJob = &findJob,
                    .listJobs = &listJobs,
                    .exec = &exec,
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
        defer self.mutex.unlock();

        const allocator = self.allocator;

        var it = self.jobs.iter();
        while (it.next()) |entry| {
            meta.free(allocator, entry.value.*);
        }

        self.jobs.deinit(allocator);
        self.upcoming.deinit();
        self.keys.deinit(allocator);
    }

    fn exec(queue: *Queue, cmd: Command) !?JobId {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (cmd) {
            .submit => |job| return self.submitJob(job),
            .start_next => return self.startNext(queue.time()),
            .retry => |id| try self.retryJob(id),
            .remove => |id| try self.removeJob(id),
            .finish => |fin| try self.handleResult(fin.id, fin.result, queue.time()),
        }

        return null;
    }

    fn submitJob(self: *MemQueue, job: JobInfo) !?JobId {
        if (job.key) |key| {
            if (self.keys.get(key)) |id| {
                if (self.jobs.find(@bitCast(id))) |existing| {
                    if (existing.state == .pending or existing.state == .running) {
                        return null;
                    }
                }
            } else {
                // Let's make a space first so we don't need to worry about errdefer
                try self.keys.ensureUnusedCapacity(self.allocator, 1);
            }
        }

        // No key specified, proceed normally
        const entry = try self.jobs.insertEntry();
        errdefer self.jobs.remove(entry.id);

        var copy = try meta.dupe(self.allocator, job);
        errdefer meta.free(self.allocator, copy);

        const id: JobId = @bitCast(entry.id);
        copy.id = id;
        entry.value.* = copy;

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

    fn findJob(queue: *Queue, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.find(@bitCast(id))) |job| {
            return try meta.dupe(arena, job.*);
        } else return null;
    }

    fn listJobs(queue: *Queue, arena: std.mem.Allocator, filter: JobFilter) ![]const JobInfo {
        const self: *MemQueue = @fieldParentPtr("interface", queue);
        self.mutex.lock();
        defer self.mutex.unlock();

        var res = try std.array_list.Managed(JobInfo).initCapacity(arena, filter.limit);
        defer res.deinit();

        var it = self.jobs.iter();
        while (it.next()) |entry| {
            if (res.items.len == filter.limit) break;
            if (filter.state) |s| if (entry.value.state != s) continue;
            if (filter.name) |n| if (!std.mem.eql(u8, entry.value.name, n)) continue;

            const copy = try meta.dupe(arena, entry.value.*);
            try res.append(copy);
        }

        return res.toOwnedSlice();
    }

    fn startNext(self: *MemQueue, time: i64) !?JobId {
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

    fn retryJob(self: *MemQueue, id: JobId) !void {
        if (self.jobs.find(@bitCast(id))) |job| {
            job.max_attempts = @min(job.max_attempts, job.attempts + 1);
            job.state = .pending;
        } else return error.JobNotFound;
    }

    fn removeJob(self: *MemQueue, id: JobId) !void {
        if (self.jobs.find(@bitCast(id))) |job| {
            if (job.key) |key| {
                _ = self.keys.remove(key);
            }
        }

        self.jobs.remove(@bitCast(id));
    }

    fn handleResult(self: *MemQueue, id: JobId, result: anyerror![]const u8, time: i64) !void {
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
    const id1 = try queue.submit("job1", "123", .{}) orelse unreachable;
    const id2 = try queue.submit("job2", "bar", .{ .key = "foo", .max_attempts = 2 }) orelse unreachable;
    try queue.push("job2", "xxx", .{ .key = "foo" });

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | data | state   | attempts |
        \\|------|-----|------|---------|----------|
        \\| job1 |     | 123  | pending | 0        |
        \\| job2 | foo | bar  | pending | 0        |
    );

    // Start first
    const next1 = (try queue.startNext()).?;
    try std.testing.expectEqual(id1, next1);

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | data | state   | attempts |
        \\|------|-----|------|---------|----------|
        \\| job1 |     | 123  | running | 1        |
        \\| job2 | foo | bar  | pending | 0        |
    );

    // Complete first
    try queue.finishJob(id1, "success");

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | data | state     | attempts | result  |
        \\|------|-----|------|-----------|----------|---------|
        \\| job1 |     | 123  | completed | 1        | success |
        \\| job2 | foo | bar  | pending   | 0        |         |
    );

    // Start second
    const next2 = (try queue.startNext()).?;
    try std.testing.expectEqual(id2, next2);

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | data | state     | attempts | result  |
        \\|------|-----|------|-----------|----------|---------|
        \\| job1 |     | 123  | completed | 1        | success |
        \\| job2 | foo | bar  | running   | 1        |         |
    );

    // Fail second
    try queue.finishJob(id2, error.TestError);

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | data | state     | attempts | result  | error     |
        \\|------|-----|------|-----------|----------|---------|-----------|
        \\| job1 |     | 123  | completed | 1        | success |           |
        \\| job2 | foo | bar  | pending   | 1        |         | TestError |
    );

    // No more jobs for now
    try std.testing.expectEqual(null, try queue.startNext());

    // Fast-forward to when retry should be available
    testing.time.value += 120;

    // Auto-restart second
    const next3 = (try queue.startNext()).?;
    try std.testing.expectEqual(id2, next3);

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | data | state     | attempts | result  | error     |
        \\|------|-----|------|-----------|----------|---------|-----------|
        \\| job1 |     | 123  | completed | 1        | success |           |
        \\| job2 | foo | bar  | running   | 2        |         | TestError |
    );

    // Fail Second Again (should be final failure since max_attempts = 2)
    try queue.finishJob(id2, error.AnotherError);

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | data | state     | attempts | result  | error        |
        \\|------|-----|------|-----------|----------|---------|--------------|
        \\| job1 |     | 123  | completed | 1        | success |              |
        \\| job2 | foo | bar  | failed    | 2        |         | AnotherError |
    );

    // No more jobs available
    try std.testing.expectEqual(null, try queue.startNext());

    // Add more
    try queue.push("test", "1", .{});
    try queue.push("test", "2", .{});
    try queue.push("other", "3", .{});

    // Filter by name
    try testing.expectTable(try queue.listJobs(arena.allocator(), .{ .name = "test" }),
        \\| name | data |
        \\|------|------|
        \\| test | 1    |
        \\| test | 2    |
    );

    // Filter by state
    try testing.expectTable(try queue.listJobs(arena.allocator(), .{ .state = .pending }),
        \\| name  | data |
        \\|-------|------|
        \\| test  | 1    |
        \\| test  | 2    |
        \\| other | 3    |
    );

    // Filter with limit
    try testing.expectTable(try queue.listJobs(arena.allocator(), .{ .limit = 1 }),
        \\| name | data |
        \\|------|------|
        \\| job1 | 123  |
    );

    // Test findJob
    const job1 = try queue.findJob(arena.allocator(), id1);
    try testing.expectEqual(job1.?.id, id1);
    try testing.expectEqual(try queue.findJob(arena.allocator(), 999999), null);
}
