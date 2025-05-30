const std = @import("std");
const testing = @import("testing.zig");
const Queue = @import("queue.zig").Queue;
const log = std.log.scoped(.cron);
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

// TODO: avoid libc
fn localtime(epoch: i64) std.enums.EnumFieldStruct(std.meta.FieldEnum(Expr), u8, null) {
    const tm = c.localtime(&epoch).*;

    return .{
        .minute = @intCast(tm.tm_min),
        .hour = @intCast(tm.tm_hour),
        .day = @intCast(tm.tm_mday),
        .month = @intCast(tm.tm_mon + 1),
        .weekday = @intCast(tm.tm_wday),
    };
}

// pub const Config = struct {
//     /// How many seconds in the past to start ticking from
//     catchup_window: i64 = 30,
// };

pub const Job = struct {
    name: []const u8,
    data: []const u8,
    schedule: Expr,
    next: i64,
};

pub const Cron = struct {
    queue: *Queue,
    jobs: std.ArrayList(Job),
    time: *const fn () i64 = std.time.timestamp,
    mutex: std.Thread.Mutex = .{},
    wait: std.Thread.Condition = .{},

    pub fn init(allocator: std.mem.Allocator, queue: *Queue) Cron {
        return .{
            .queue = queue,
            .jobs = .init(allocator),
        };
    }

    pub fn deinit(self: *Cron) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.jobs.deinit();
    }

    // TODO: return id
    pub fn schedule(self: *Cron, name: []const u8, data: []const u8, expr: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const exp = try Expr.parse(expr);
        const next = exp.next(self.time());

        try self.jobs.append(.{
            .name = name,
            .data = data,
            .schedule = exp,
            .next = next,
        });
    }

    // TODO: unschedule(id)

    pub fn run(self: *Cron) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var step = self.time(); // - self.config.catchup_window;

        while (step < self.time()) {
            log.debug("catching up to {}", .{step});
            step = try self.tick(step);
        }

        while (true) {
            step = try self.tick(step);

            // Wait until the next tick
            const wait: u64 = @intCast(@max(0, step - self.time()));
            log.debug("sleeping for {}", .{wait});
            self.wait.timedWait(&self.mutex, wait * std.time.ns_per_s) catch break;
        }
    }

    pub fn tick(self: *Cron, now: i64) !i64 {
        var next_tick: i64 = 60;

        for (self.jobs.items) |*job| {
            if (job.next <= now) {
                var buf: [20]u8 = undefined;

                _ = try self.queue.enqueue(job.name, job.data, .{
                    .key = std.fmt.bufPrintIntToSlice(&buf, job.next, 10, .lower, .{}),
                    .schedule_at = job.next,
                });

                job.next = job.schedule.next(now);
                next_tick = @min(next_tick, job.next);
            }
        }

        return next_tick;
    }
};

test Cron {
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    var cron = Cron.init(testing.allocator, &queue);
    defer cron.deinit();

    testing.time.value = 0;
    cron.time = &testing.time.get;

    // Only used for listing
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try cron.schedule("bar", "baz", "* * * * *");

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | state   |
        \\|------|-----|---------|
    );

    _ = try cron.tick(60);

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | state   |
        \\|------|-----|---------|
        \\| bar  | 60  | pending |
    );

    _ = try cron.tick(120);

    try testing.expectTable(try queue.getAllJobs(arena.allocator()),
        \\| name | key | state   |
        \\|------|-----|---------|
        \\| bar  | 60  | pending |
        \\| bar  | 120 | pending |
    );
}

pub const Expr = struct {
    minute: std.StaticBitSet(60), // 0-59
    hour: std.StaticBitSet(24), // 0-23
    day: std.StaticBitSet(32), // 1-31 !!!
    month: std.StaticBitSet(13), // 1-12 !!!
    weekday: std.StaticBitSet(7), // 0-6

    pub fn match(self: *const Expr, epoch: i64) bool {
        const tm = localtime(epoch);

        inline for (std.meta.fields(Expr)) |f| {
            if (!@field(self, f.name).isSet(@field(tm, f.name))) {
                return false;
            }
        }

        return true;
    }

    pub fn next(self: *const Expr, now: i64) i64 {
        var res = now + 60 - @mod(now, 60);
        while (!self.match(res)) : (res += 60) {}
        return res;
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
            return T.initFull();
        }

        var res = T.initEmpty();

        var it = std.mem.tokenizeScalar(u8, field, ',');
        while (it.next()) |part| {
            if (std.mem.startsWith(u8, part, "*/")) {
                const freq = try std.fmt.parseInt(T.MaskInt, part[2..], 10);
                if (@mod(T.bit_length, freq) != 0) return error.InvalidFrequency;

                var i: T.MaskInt = 0;
                while (i < T.bit_length) : (i += freq) {
                    res.set(i);
                }
            } else if (std.mem.indexOf(u8, part, "-")) |i| {
                const start = try std.fmt.parseInt(u8, part[0..i], 10);
                const end = try std.fmt.parseInt(u8, part[i + 1 ..], 10);

                if (start > end) return error.InvalidRange;

                for (start..end + 1) |n| {
                    res.set(n);
                }
            } else {
                res.set(try std.fmt.parseInt(T.MaskInt, part, 10));
            }
        }

        return res;
    }
};

test "Expr.parse()" {
    const expect = std.testing.expect;

    const ex1 = try Expr.parse("* * * * *");
    try expect(ex1.minute.mask == ~@as(u60, 0));
    try expect(ex1.hour.mask == ~@as(u24, 0));
    try expect(ex1.day.mask == ~@as(u32, 0));
    try expect(ex1.month.mask == ~@as(u13, 0));
    try expect(ex1.weekday.mask == ~@as(u7, 0));

    const ex2 = try Expr.parse("*/5 * * * *");
    try expect(ex2.minute.isSet(0));
    try expect(!ex2.minute.isSet(1));
    try expect(ex2.minute.isSet(5));
    try expect(!ex2.minute.isSet(6));

    const ex3 = try Expr.parse("0 0 31 1 *");
    try expect(ex3.minute.isSet(0));
    try expect(ex3.hour.isSet(0));
    try expect(ex3.day.isSet(31));
    try expect(ex3.month.isSet(1));
    try expect(ex3.weekday.mask == ~@as(u7, 0));

    const ex4 = try Expr.parse("0-1 * * * *");
    try expect(ex4.minute.isSet(0));
    try expect(ex4.minute.isSet(1));
    try expect(!ex4.minute.isSet(2));

    const ex5 = try Expr.parse("0,1-2 * * * *");
    try expect(ex5.minute.isSet(0));
    try expect(ex5.minute.isSet(1));
    try expect(ex5.minute.isSet(2));
    try expect(!ex5.minute.isSet(3));

    const ex6 = try Expr.parse("0,1-2,4-5,*/5 * * * *");
    try expect(ex6.minute.isSet(0));
    try expect(ex6.minute.isSet(1));
    try expect(ex6.minute.isSet(2));
    try expect(!ex6.minute.isSet(3));
    try expect(ex6.minute.isSet(4));
    try expect(ex6.minute.isSet(5));
    try expect(!ex6.minute.isSet(6));
    try expect(ex6.minute.isSet(10));
    try expect(ex6.minute.isSet(15));
}

fn expectMatch(expr: []const u8, matches: anytype) !void {
    const ex = try Expr.parse(expr);

    inline for (matches) |m| {
        errdefer std.debug.print("match failed: {}\n", .{m});

        try std.testing.expectEqual(m[1], ex.match(m[0]));
    }
}

test "expr.match()" {
    _ = c.setenv("TZ", "UTC", 1);
    c.tzset();

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

        try std.testing.expectEqual(m[1], ex.next(m[0]));
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
}
