const std = @import("std");
const testing = @import("testing.zig");
const Time = @import("time.zig").Time;
const Queue = @import("queue.zig").Queue;
const MemQueue = @import("queue.zig").MemQueue;
const log = std.log.scoped(.cron);

const JobId = enum(usize) { _ };

pub const Config = struct {
    /// How many seconds in the past to start ticking from
    catchup_window: i64 = 30,
};

pub const Job = struct {
    id: JobId,
    schedule: Expr,
    name: []const u8,
    data: []const u8,
    next: Time,
};

pub const Cron = struct {
    config: Config,
    queue: *Queue,
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(Job),
    time: *const fn () Time = Time.now,
    mutex: std.Thread.Mutex = .{},
    wait: std.Thread.Condition = .{},

    // NOTE: global & shared
    var next_id: std.atomic.Value(usize) = .init(1);

    pub fn init(allocator: std.mem.Allocator, queue: *Queue, config: Config) Cron {
        return .{
            .config = config,
            .queue = queue,
            .allocator = allocator,
            .jobs = .{},
        };
    }

    pub fn deinit(self: *Cron) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.jobs.deinit(self.allocator);
    }

    pub fn schedule(self: *Cron, expr: []const u8, name: []const u8, data: []const u8) !JobId {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id: JobId = @enumFromInt(next_id.fetchAdd(1, .monotonic));
        const exp = try Expr.parse(expr);
        const next = exp.next(self.time());

        try self.jobs.append(self.allocator, .{
            .id = id,
            .schedule = exp,
            .name = name,
            .data = data,
            .next = next,
        });

        return id;
    }

    pub fn unschedule(self: *Cron, id: JobId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.jobs.items, 0..) |job, i| {
            if (job.id == id) {
                _ = self.jobs.swapRemove(i);
                break;
            }
        }
    }

    pub fn run(self: *Cron) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var step = Time.unix(self.time().epoch - self.config.catchup_window);

        if (self.config.catchup_window > 0) {
            // NOTE: cron.schedule() appends each job with .next relative to the current time so we need to undo that
            for (self.jobs.items) |*job| {
                job.next = job.schedule.next(step);
            }

            while (step.epoch < self.time().epoch) {
                log.debug("catching up to {f}", .{step});
                step = try self.tick(step);
            }
        }

        while (true) {
            step = try self.tick(step);

            // Wait until the next tick
            const wait: u64 = @intCast(@max(0, step.epoch - self.time().epoch));
            log.debug("sleeping for {}", .{wait});
            self.wait.timedWait(&self.mutex, wait * std.time.ns_per_s) catch break;
        }
    }

    pub fn tick(self: *Cron, now: Time) !Time {
        var next_tick = now.next(.minute);

        for (self.jobs.items) |*job| {
            if (job.next.epoch <= now.epoch) {
                var buf: [20]u8 = undefined;

                log.debug("scheduling {s} {s}", .{ job.name, job.data });
                try self.queue.push(job.name, job.data, .{
                    .key = try std.fmt.bufPrint(&buf, "{d}", .{job.next.epoch}),
                    .schedule_at = job.next.epoch,
                });

                job.next = job.schedule.next(now);
                next_tick.epoch = @min(next_tick.epoch, job.next.epoch);
            }
        }

        return next_tick;
    }
};

test Cron {
    var mem_queue = try MemQueue.init(testing.allocator);
    defer mem_queue.deinit();

    const queue = &mem_queue.interface;

    var cron = Cron.init(testing.allocator, queue, .{});
    defer cron.deinit();

    testing.time.value = 0;
    cron.time = &testing.time.getTime;

    // Only used for listing
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const id = try cron.schedule("* * * * *", "bar", "baz");

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | state   |
        \\|------|-----|---------|
    );

    _ = try cron.tick(.unix(60));

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | state   |
        \\|------|-----|---------|
        \\| bar  | 60  | pending |
    );

    _ = try cron.tick(.unix(120));

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | state   |
        \\|------|-----|---------|
        \\| bar  | 60  | pending |
        \\| bar  | 120 | pending |
    );

    cron.unschedule(id);
    _ = try cron.tick(.unix(180));

    try testing.expectTable(try queue.listJobs(arena.allocator(), .{}),
        \\| name | key | state   |
        \\|------|-----|---------|
        \\| bar  | 60  | pending |
        \\| bar  | 120 | pending |
    );
}

pub const Expr = struct {
    minute: u60, // 0-59
    hour: u24, // 0-23
    day: u32, // 1-31
    month: u13, // 1-12
    weekday: u7, // 0-6

    pub fn match(self: *const Expr, step: Time) bool {
        const date = step.date();

        return isSet(self.minute, step.minute()) and
            isSet(self.hour, step.hour()) and
            isSet(self.day, date.day) and
            isSet(self.month, date.month) and
            isSet(self.weekday, date.dayOfWeek());
    }

    pub fn next(self: *const Expr, since: Time) Time {
        var res = since.next(.minute);
        while (!self.match(res)) : (res = res.next(.minute)) {}
        return res;
    }

    // pub fn next(self: *const Expr, since: Time) Time {
    //     while (true) {
    //         var res = since.setSecond(0);
    //         // std.debug.print("{}\n", .{res});

    //         if (findNext(self.minute, res.minute())) |min| {
    //             res = res.setMinute(min);
    //             if (self.match(res)) return res;
    //         }
    //         res = res.setMinute(findFirst(self.minute));

    //         if (findNext(self.hour, res.hour())) |hour| {
    //             res = res.setHour(hour);
    //             if (self.match(res)) return res;
    //         }
    //         res = res.setHour(findFirst(self.hour));

    //         // TODO: remove the loop once we fix this
    //         // if (findNext(self.day, res.day())) |day| {
    //         //     res = res.setDay(day);
    //         //     if (self.match(res)) return res;
    //         // }
    //         // res = res.setDay(findFirst(self.day));

    //         // if (findNext(self.month, res.month())) |month| {
    //         //     res = res.setMonth(month);
    //         //     if (self.match(res)) return res;
    //         // }
    //         // res = res.setMonth(findFirst(self.month));
    //         // return res.add(.years, 1);

    //         if (self.match(res)) return res;
    //         res = res.add(.days, 1);
    //         if (self.match(res)) return res;
    //     }
    // }

    fn findNext(mask: anytype, curr: u32) ?u32 {
        // std.debug.print("find next:  {b:.>32} {}\n", .{ mask, curr });
        var n = curr + 1;
        while (n < @bitSizeOf(@TypeOf(mask))) : (n += 1) {
            if (isSet(mask, n)) return n;
        } else return null;
    }

    fn findFirst(mask: anytype) u32 {
        // std.debug.print("find first: {b:.>32}\n", .{mask});
        return @intCast(@ctz(mask));
    }

    pub fn parse(expr: []const u8) !Expr {
        var it = std.mem.tokenizeScalar(u8, expr, ' ');
        var res: Expr = undefined;

        inline for (std.meta.fields(Expr)) |f| {
            @field(res, f.name) = try parseField(
                f.type,
                it.next() orelse return error.MissingField,
            );
        }

        return res;
    }

    fn parseField(comptime T: type, field: []const u8) !T {
        if (std.mem.eql(u8, field, "*")) {
            return ~@as(T, 0);
        }

        var mask: u64 = 0;

        var it = std.mem.tokenizeScalar(u8, field, ',');
        while (it.next()) |part| {
            if (std.mem.startsWith(u8, part, "*/")) {
                const freq = try std.fmt.parseInt(u8, part[2..], 10);
                if (@mod(@bitSizeOf(T), freq) != 0) return error.InvalidFrequency;

                var i: u8 = 0;
                while (i < @bitSizeOf(T)) : (i += freq) {
                    mask |= maskBit(i);
                }
            } else if (std.mem.indexOf(u8, part, "-")) |i| {
                const start = try std.fmt.parseInt(u8, part[0..i], 10);
                const end = try std.fmt.parseInt(u8, part[i + 1 ..], 10);

                if (start > end) return error.InvalidRange;

                for (start..end + 1) |n| {
                    mask |= maskBit(@intCast(n));
                }
            } else {
                mask |= maskBit(try std.fmt.parseInt(u8, part, 10));
            }
        }

        return @truncate(mask);
    }
};

fn maskBit(n: u32) u64 {
    return @as(u64, 1) << @intCast(n);
}

fn isSet(mask: u64, bit: u32) bool {
    return (mask & @as(u64, 1) << @intCast(bit)) != 0;
}

test "Expr.parse()" {
    const expect = std.testing.expect;

    const ex1 = try Expr.parse("* * * * *");
    try expect(ex1.minute == ~@as(u60, 0));
    try expect(ex1.hour == ~@as(u24, 0));
    try expect(ex1.day == ~@as(u32, 0));
    try expect(ex1.month == ~@as(u13, 0));
    try expect(ex1.weekday == ~@as(u7, 0));

    const ex2 = try Expr.parse("*/5 * * * *");
    try expect(isSet(ex2.minute, 0));
    try expect(!isSet(ex2.minute, 1));
    try expect(isSet(ex2.minute, 5));
    try expect(!isSet(ex2.minute, 6));

    const ex3 = try Expr.parse("0 0 31 1 *");
    try expect(isSet(ex3.minute, 0));
    try expect(isSet(ex3.hour, 0));
    try expect(isSet(ex3.day, 31));
    try expect(isSet(ex3.month, 1));
    try expect(ex3.weekday == ~@as(u7, 0));

    const ex4 = try Expr.parse("0-1 * * * *");
    try expect(isSet(ex4.minute, 0));
    try expect(isSet(ex4.minute, 1));
    try expect(!isSet(ex4.minute, 2));

    const ex5 = try Expr.parse("0,1-2 * * * *");
    try expect(isSet(ex5.minute, 0));
    try expect(isSet(ex5.minute, 1));
    try expect(isSet(ex5.minute, 2));
    try expect(!isSet(ex5.minute, 3));

    const ex6 = try Expr.parse("0,1-2,4-5,*/5 * * * *");
    try expect(isSet(ex6.minute, 0));
    try expect(isSet(ex6.minute, 1));
    try expect(isSet(ex6.minute, 2));
    try expect(!isSet(ex6.minute, 3));
    try expect(isSet(ex6.minute, 4));
    try expect(isSet(ex6.minute, 5));
    try expect(!isSet(ex6.minute, 6));
    try expect(isSet(ex6.minute, 10));
    try expect(isSet(ex6.minute, 15));
}

fn expectMatch(expr: []const u8, matches: anytype) !void {
    const ex = try Expr.parse(expr);

    inline for (matches) |m| {
        errdefer std.debug.print("match failed: {}\n", .{m});

        try std.testing.expectEqual(m[1], ex.match(.unix(m[0])));
    }
}

test "expr.match()" {
    try expectMatch("* * * * *", .{
        .{ 0, true },
        .{ 60, true },
        .{ std.time.timestamp(), true },
    });

    try expectMatch("*/5 * * * *", .{
        .{ 0, true },
        .{ 1 * 60, false },
        .{ 5 * 60, true },
        .{ 6 * 60, false },
    });

    try expectMatch("*/30 * * * *", .{
        .{ 0, true },
        .{ 1 * 60, false },
        .{ 30 * 60, true },
        .{ 31 * 60, false },
    });

    try expectMatch("0 * 1 1 *", .{
        .{ 0, true },
        .{ 3600, true },
        .{ 23 * 3600, true },
        .{ 24 * 3600, false },
    });

    try expectMatch("0 0 31 1 *", .{
        .{ 0, false },
        .{ 30 * 24 * 3600, true },
    });
}

fn expectNext(expr: []const u8, matches: anytype) !void {
    const ex = try Expr.parse(expr);

    inline for (matches) |m| {
        errdefer std.debug.print("match failed: {}\n", .{m});

        try std.testing.expectEqual(m[1], ex.next(.unix(m[0])).epoch);
    }
}

test "expr.next()" {
    try expectNext("* * * * *", .{
        .{ 0, 60 },
        .{ 1, 60 },
        .{ 59, 60 },
        .{ 60, 120 },
        .{ 61, 120 },
    });

    try expectNext("*/5 * * * *", .{
        .{ 0, 5 * 60 },
        .{ 5 * 60, 10 * 60 },
    });

    try expectNext("0 */6 * * *", .{
        .{ 0, 6 * 3600 }, // 00:00 -> 06:00
        .{ 6 * 3600, 12 * 3600 }, // 06:00 -> 12:00
    });

    try expectNext("30 2,14 * * *", .{
        .{ 0, 2 * 3600 + 30 * 60 }, // 00:00 -> 02:30
        .{ 2 * 3600 + 30 * 60, 14 * 3600 + 30 * 60 }, // 02:30 -> 14:30
    });

    try expectNext("0 0 * * *", .{
        .{ 23 * 3600 + 59 * 60, 24 * 3600 }, // 23:59 -> 00:00 next day
    });

    try expectNext("0 0 15 * *", .{
        .{ 0, 14 * 24 * 3600 }, // Jan 1 -> Jan 15
        .{ 16 * 24 * 3600, 31 * 24 * 3600 + 14 * 24 * 3600 }, // Jan 17 -> Feb 15
    });

    try expectNext("0 9 * * 1", .{
        .{ 0, 4 * 24 * 3600 + 9 * 3600 }, // Jan 1 (Thu) -> Jan 5 (Mon) 9:00
        .{ 4 * 24 * 3600 + 9 * 3600, 11 * 24 * 3600 + 9 * 3600 }, // Jan 5 (Mon) -> Jan 12 (Mon) 9:00
    });
}
