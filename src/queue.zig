const std = @import("std");
const meta = @import("meta.zig");

pub const JobInfo = struct {
    id: u32,
    name: []const u8,
    data: []const u8,
};

pub const JobOptions = struct {
    /// Optional key for deduplication.
    key: ?[]const u8 = null,
    /// Maximum number of attempts allowed.
    max_attempts: u32 = 1,
    /// Optional timestamp to schedule the job.
    schedule_at: ?i64 = null,
};

// TODO: this impl should be just a backend for the Queue interface
pub const Queue = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayListUnmanaged(JobInfo),
    running: std.ArrayListUnmanaged(JobInfo),
    completed: std.ArrayListUnmanaged(JobInfo),
    failed: std.ArrayListUnmanaged(JobInfo),
    mutex: std.Thread.Mutex = .{},

    var next_id: std.atomic.Value(u32) = .init(1);

    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{
            .allocator = allocator,
            .pending = .empty,
            .running = .empty,
            .completed = .empty,
            .failed = .empty,
        };
    }

    pub fn deinit(self: *Queue) void {
        inline for (.{ "pending", "running", "completed", "failed" }) |list| {
            for (@field(self, list).items) |it| self.allocator.free(it.data);
            @field(self, list).deinit(self.allocator);
        }
    }

    pub fn enqueue(self: *Queue, name: []const u8, data: anytype, options: JobOptions) !void {
        // TODO: implement this
        _ = options;

        const data_str: []const u8 = if (comptime meta.isString(@TypeOf(data)))
            try meta.dupe(self.allocator, data)
        else
            try std.json.stringifyAlloc(self.pending.allocator, data, .{});

        try self.pending.append(self.allocator, JobInfo{
            .id = next_id.fetchAdd(1, .monotonic),
            .name = name,
            .data = data_str,
        });
    }

    pub fn getPendingJobs(self: *Queue, allocator: std.mem.Allocator) ![]const JobInfo {
        return meta.dupe(allocator, self.pending.items);
    }

    pub fn getRunningJobs(self: *Queue, allocator: std.mem.Allocator) ![]const JobInfo {
        return meta.dupe(allocator, self.running.items);
    }

    pub fn getCompletedJobs(self: *Queue, allocator: std.mem.Allocator) ![]const JobInfo {
        return meta.dupe(allocator, self.completed.items);
    }

    pub fn getFailedJobs(self: *Queue, allocator: std.mem.Allocator) ![]const JobInfo {
        return meta.dupe(allocator, self.failed.items);
    }
};
