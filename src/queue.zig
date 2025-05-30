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
    backend: QueueBackend,
    time: *const fn () i64 = std.time.timestamp,

    pub fn init(allocator: std.mem.Allocator) !Queue {
        return Queue.initWithBackend(DefaultBackend, allocator);
    }

    pub fn initWithBackend(comptime B: type, allocator: std.mem.Allocator) !Queue {
        const backend = try B.init(allocator);

        return .{
            .backend = meta.upcast(backend, QueueBackend),
        };
    }

    pub fn deinit(self: *Queue) void {
        self.backend.deinit();
    }

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

        return self.backend.enqueue(job);
    }

    pub fn getJobInfo(self: *Queue, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        return self.backend.getJobInfo(arena, id);
    }

    pub fn getAllJobs(self: *Queue, arena: std.mem.Allocator) ![]JobInfo {
        return self.backend.getAllJobs(arena);
    }

    pub fn startNext(self: *Queue) !?JobId {
        return self.backend.startNext(self.time());
    }

    pub fn startJob(self: *Queue, id: JobId) !bool {
        return self.backend.startJob(id);
    }

    pub fn retryJob(self: *Queue, id: JobId) !void {
        return self.backend.retryJob(id);
    }

    pub fn removeJob(self: *Queue, id: JobId) !void {
        return self.backend.removeJob(id);
    }

    pub fn handleSuccess(self: *Queue, id: JobId, res: anytype) !void {
        return self.backend.handleSuccess(id, res, self.time());
    }

    pub fn handleFailure(self: *Queue, id: JobId, err: anyerror) !void {
        return self.backend.handleFailure(id, err, self.time());
    }
};

pub const QueueBackend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = anyerror; // TODO

    pub const VTable = struct {
        enqueue: *const fn (context: *anyopaque, job: JobInfo) Error!?JobId,
        getJobInfo: *const fn (context: *anyopaque, arena: std.mem.Allocator, id: JobId) Error!?JobInfo,
        getAllJobs: *const fn (context: *anyopaque, arena: std.mem.Allocator) Error![]JobInfo,
        startNext: *const fn (context: *anyopaque, time: i64) Error!?JobId,
        startJob: *const fn (context: *anyopaque, id: JobId) Error!bool,
        retryJob: *const fn (context: *anyopaque, id: JobId) Error!void,
        removeJob: *const fn (context: *anyopaque, id: JobId) Error!void,
        handleSuccess: *const fn (context: *anyopaque, id: JobId, res: []const u8, time: i64) Error!void,
        handleFailure: *const fn (context: *anyopaque, id: JobId, err: anyerror, time: i64) Error!void,
        deinit: *const fn (context: *anyopaque) void,
    };

    pub fn enqueue(self: *QueueBackend, job: JobInfo) !?JobId {
        return self.vtable.enqueue(self.context, job);
    }

    pub fn getJobInfo(self: *QueueBackend, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        return self.vtable.getJobInfo(self.context, arena, id);
    }

    pub fn getAllJobs(self: *QueueBackend, arena: std.mem.Allocator) ![]JobInfo {
        return self.vtable.getAllJobs(self.context, arena);
    }

    pub fn startNext(self: *QueueBackend, time: i64) !?JobId {
        return self.vtable.startNext(self.context, time);
    }

    pub fn startJob(self: *QueueBackend, id: JobId) !bool {
        return self.vtable.startJob(self.context, id);
    }

    pub fn retryJob(self: *QueueBackend, id: JobId) !void {
        return self.vtable.retryJob(self.context, id);
    }

    pub fn removeJob(self: *QueueBackend, id: JobId) !void {
        return self.vtable.removeJob(self.context, id);
    }

    pub fn handleSuccess(self: *QueueBackend, id: JobId, res: anytype, time: i64) !void {
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const result_str: []const u8 = switch (@TypeOf(res)) {
            void => "",
            else => blk: {
                try std.json.stringify(res, .{}, fbs.writer());
                break :blk fbs.getWritten();
            },
        };
        return self.vtable.handleSuccess(self.context, id, result_str, time);
    }

    pub fn handleFailure(self: *QueueBackend, id: JobId, err: anyerror, time: i64) !void {
        return self.vtable.handleFailure(self.context, id, err, time);
    }

    pub fn deinit(self: *QueueBackend) void {
        self.vtable.deinit(self.context);
    }
};

pub const DefaultBackend = struct {
    mutex: std.Thread.Mutex.Recursive = .init,
    allocator: std.mem.Allocator,
    jobs: util.SlotMap(JobInfo),
    upcoming: std.PriorityQueue(Schedule, void, cmpSchedule),
    keys: std.StringHashMapUnmanaged(JobId),

    const Schedule = struct {
        id: JobId,
        scheduled_at: ?i64,
    };

    pub fn init(allocator: std.mem.Allocator) !*DefaultBackend {
        const self = try allocator.create(DefaultBackend);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .jobs = try .initAlloc(allocator, 4),
            .upcoming = .init(allocator, {}),
            .keys = .empty,
        };

        return self;
    }

    pub fn deinit(self: *DefaultBackend) void {
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
        allocator.destroy(self);
    }

    pub fn enqueue(self: *DefaultBackend, job: JobInfo) !?JobId {
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

    pub fn getJobInfo(self: *DefaultBackend, arena: std.mem.Allocator, id: JobId) !?JobInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.find(@bitCast(id)) orelse {
            return error.JobNotFound; // try self.getJob?
        };

        var copy = try meta.dupe(arena, job.*);
        copy.id = @bitCast(job.id.?);

        return copy;
    }

    pub fn getAllJobs(self: *DefaultBackend, arena: std.mem.Allocator) ![]JobInfo {
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

    pub fn startNext(self: *DefaultBackend, time: i64) !?JobId {
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

    pub fn startJob(self: *DefaultBackend, id: JobId) !bool {
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

    pub fn retryJob(self: *DefaultBackend, id: JobId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.find(@bitCast(id))) |job| {
            job.max_attempts = @min(job.max_attempts, job.attempts + 1);
            job.state = .pending;
        } else return error.JobNotFound;
    }

    pub fn removeJob(self: *DefaultBackend, id: JobId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.find(@bitCast(id))) |job| {
            if (job.key) |key| {
                _ = self.keys.remove(key);
            }
        }

        self.jobs.remove(@bitCast(id));
    }

    pub fn handleSuccess(self: *DefaultBackend, id: JobId, result: []const u8, time: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.find(@bitCast(id)) orelse {
            return error.JobNotFound;
        };

        const new_result = try self.allocator.dupe(u8, result);
        errdefer self.allocator.free(new_result);

        // Free old
        if (job.result) |old| {
            self.allocator.free(old);
        }

        job.state = .completed;
        job.result = new_result;
        job.@"error" = null;
        job.completed_at = time;
    }

    pub fn handleFailure(self: *DefaultBackend, id: JobId, err: anyerror, time: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.find(@bitCast(id)) orelse {
            return error.JobNotFound;
        };

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

    fn cmpSchedule(_: void, a: Schedule, b: Schedule) std.math.Order {
        return std.math.order(a.scheduled_at orelse 0, b.scheduled_at orelse 0);
    }
};

test Queue {
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

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
