// https://www.youtube.com/watch?v=0s9F4QWAl-E
// https://onlinelibrary.wiley.com/doi/full/10.1002/spe.3172
// https://howardhinnant.github.io/date_algorithms.html
// https://en.wikipedia.org/wiki/Rata_Die
const std = @import("std");

const RATA_TO_UNIX = 719468;
const EOD = 86_400 - 1;

pub const TimeUnit = enum { second, minute, hour, day, month, year };
pub const DateUnit = enum { day, month, year };

// Taken from the video
pub fn isLeapYear(year: i32) bool {
    const d: i32 = if (@mod(year, 100) != 0) 4 else 16;
    return (year & (d - 1)) == 0;
}

// TODO: IIRC there was also some formula
fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable,
    };
}

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn parse(str: []const u8) !Date {
        var it = std.mem.splitScalar(u8, str, '-');
        return ymd(
            try std.fmt.parseInt(i32, it.next() orelse return error.Eof, 10),
            try std.fmt.parseInt(u8, it.next() orelse return error.Eof, 10),
            try std.fmt.parseInt(u8, it.next() orelse return error.Eof, 10),
        );
    }

    pub fn ymd(year: i32, month: u8, day: u8) Date {
        return .{
            .year = year,
            .month = month,
            .day = day,
        };
    }

    pub fn today() Date {
        return Time.now().date();
    }

    pub fn yesterday() Date {
        return today().add(.day, -1);
    }

    pub fn tomorrow() Date {
        return today().add(.day, 1);
    }

    pub fn startOf(unit: DateUnit) Date {
        return today().setStartOf(unit);
    }

    pub fn endOf(unit: DateUnit) Date {
        return today().setEndOf(unit);
    }

    pub fn setStartOf(self: Date, unit: DateUnit) Date {
        return switch (unit) {
            .day => self,
            .month => ymd(self.year, self.month, 1),
            .year => ymd(self.year, 1, 1),
        };
    }

    pub fn setEndOf(self: Date, unit: DateUnit) Date {
        return switch (unit) {
            .day => self,
            .month => ymd(self.year, self.month, daysInMonth(self.year, self.month)),
            .year => ymd(self.year, 12, 31),
        };
    }

    pub fn add(self: Date, part: DateUnit, amount: i64) Date {
        return switch (part) {
            .day => {
                const time = Time.unix(0).setDate(self);
                return time.add(.days, amount).date();
            },
            .month => @panic("TODO"),
            .year => {
                const new_year = self.year + @as(i32, @intCast(amount));
                return ymd(new_year, self.month, self.day);
            },
        };
    }

    pub fn dayOfWeek(self: Date) u8 {
        const rata_day = date_to_rata(self);
        return @mod(rata_day + 3, 7);
    }

    pub fn format(self: Date, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d}-{d:0>2}-{d:0>2}", .{
            @as(u32, @intCast(self.year)),
            self.month,
            self.day,
        });
    }
};

pub const Time = struct {
    epoch: i64,

    pub fn unix(epoch: i64) Time {
        return .{ .epoch = epoch };
    }

    pub fn now() Time {
        return unix(std.time.timestamp());
    }

    pub fn today() Time {
        return unix(0).setDate(.today());
    }

    pub fn tomorrow() Time {
        return unix(0).setDate(.tomorrow());
    }

    pub fn startOf(unit: TimeUnit) Time {
        return Time.now().setStartOf(unit);
    }

    pub fn endOf(unit: TimeUnit) Time {
        return Time.now().setEndOf(unit);
    }

    pub fn second(self: Time) u32 {
        return @intCast(@mod(self.total(.seconds), 60));
    }

    pub fn setSecond(self: Time, sec: u32) Time {
        return self.add(.seconds, @as(i64, sec) - self.second());
    }

    pub fn minute(self: Time) u32 {
        return @intCast(@mod(self.total(.minutes), 60));
    }

    pub fn setMinute(self: Time, min: u32) Time {
        return self.add(.minutes, @as(i64, min) - self.minute());
    }

    pub fn hour(self: Time) u32 {
        return @intCast(@mod(self.total(.hours), 24));
    }

    pub fn setHour(self: Time, hr: u32) Time {
        return self.add(.hours, @as(i64, hr) - self.hour());
    }

    pub fn date(self: Time) Date {
        return rata_to_date(@divTrunc(self.epoch, std.time.s_per_day) + RATA_TO_UNIX);
    }

    pub fn setDate(self: Time, dat: Date) Time {
        var res: i64 = @mod(self.epoch, std.time.s_per_day);
        res += (date_to_rata(dat) - RATA_TO_UNIX) * std.time.s_per_day;
        return unix(res);
    }

    pub fn setStartOf(self: Time, unit: TimeUnit) Time {
        // TODO: continue :label?
        return switch (unit) {
            .second => self,
            .minute => self.setSecond(0),
            .hour => self.setSecond(0).setMinute(0),
            .day => self.setSecond(0).setMinute(0).setHour(0),
            .month => {
                const d = self.date();
                return unix(0).setDate(.ymd(d.year, d.month, 1));
            },
            .year => {
                const d = self.date();
                return unix(0).setDate(.ymd(d.year, 1, 1));
            },
        };
    }

    // TODO: rename to startOfNext?
    pub fn next(self: Time, unit: enum { second, minute, hour, day }) Time {
        return switch (unit) {
            .second => self.add(.seconds, 1),
            .minute => self.setSecond(0).add(.minutes, 1),
            .hour => self.setSecond(0).setMinute(0).add(.hours, 1),
            .day => self.setSecond(0).setMinute(0).setHour(0).add(.hours, 24),
        };
    }

    pub fn setEndOf(self: Time, unit: TimeUnit) Time {
        // TODO: continue :label?
        return switch (unit) {
            .second => self,
            .minute => self.setSecond(59),
            .hour => self.setSecond(59).setMinute(59),
            .day => self.setSecond(59).setMinute(59).setHour(23),
            .month => {
                const d = self.date();
                return unix(EOD).setDate(.ymd(d.year, d.month, daysInMonth(d.year, d.month)));
            },
            .year => {
                const d = self.date();
                return unix(EOD).setDate(.ymd(d.year, 12, 31));
            },
        };
    }

    pub fn add(self: Time, part: enum { seconds, minutes, hours, days, months, years }, amount: i64) Time {
        const n = switch (part) {
            .seconds => amount,
            .minutes => amount * std.time.s_per_min,
            .hours => amount * std.time.s_per_hour,
            .days => amount * std.time.s_per_day,
            .months => @panic("TODO"),
            .years => return self.add(.days, if (isLeapYear(self.date().year)) 366 else 365),
        };

        return .{ .epoch = self.epoch + n };
    }

    fn total(self: Time, part: enum { seconds, minutes, hours }) i64 {
        return switch (part) {
            .seconds => self.epoch,
            .minutes => @divTrunc(self.epoch, std.time.s_per_min),
            .hours => @divTrunc(self.epoch, std.time.s_per_hour),
        };
    }

    pub fn format(self: Time, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
            self.date(),
            self.hour(),
            self.minute(),
            self.second(),
        });
    }
};

// https://github.com/cassioneri/eaf/blob/1509faf37a0e0f59f5d4f11d0456fd0973c08f85/eaf/gregorian.hpp#L42
fn rata_to_date(N: i64) Date {
    // Century.
    const N_1: i64 = 4 * N + 3;
    const C: i64 = quotient(N_1, 146097);
    const N_C: u32 = remainder(N_1, 146097) / 4;

    // Year.
    const N_2 = 4 * N_C + 3;
    const Z: u32 = N_2 / 1461;
    const N_Y: u32 = N_2 % 1461 / 4;
    const Y: i64 = 100 * C + Z;

    // Month and day.
    const N_3: u32 = 5 * N_Y + 461;
    const M: u32 = N_3 / 153;
    const D: u32 = N_3 % 153 / 5;

    // Map.
    const J: u32 = @intFromBool(M >= 13);

    return .{
        .year = @intCast(Y + J),
        .month = @intCast(M - 12 * J),
        .day = @intCast(D + 1),
    };
}

// https://github.com/cassioneri/eaf/blob/1509faf37a0e0f59f5d4f11d0456fd0973c08f85/eaf/gregorian.hpp#L88
fn date_to_rata(date: Date) i32 {
    // Map.
    const J: u32 = @intFromBool(date.month <= 2);
    const Y: i32 = date.year - @as(i32, @intCast(J));
    const M: u32 = date.month + 12 * J;
    const D: u32 = date.day - 1;
    const C: i32 = @intCast(quotient(Y, 100));

    // Rata die.
    const y_star: i32 = @intCast(quotient(1461 * Y, 4) - C + quotient(C, 4)); // n_days in all prev. years
    const m_star: u32 = (153 * M - 457) / 5; // n_days in prev. months

    return y_star + @as(i32, @intCast(m_star)) + @as(i32, @intCast(D));
}

fn quotient(n: i64, d: u32) i64 {
    return if (n >= 0) @divTrunc(n, d) else @divTrunc((n + 1), d) - 1;
}

fn remainder(n: i64, d: u32) u32 {
    return @intCast(if (n >= 0) @mod(n, d) else (n + d) - d * quotient((n + d), d));
}

const testing = @import("testing.zig");

test "basic usage" {
    const t1 = Time.unix(1234567890);
    try testing.expectFmt(t1, "2009-02-13 23:31:30 UTC");

    try testing.expectEqual(t1.date(), .{
        .year = 2009,
        .month = 2,
        .day = 13,
    });

    try testing.expectEqual(t1.hour(), 23);
    try testing.expectEqual(t1.minute(), 31);
    try testing.expectEqual(t1.second(), 30);

    const t2 = t1.setHour(10).setMinute(15).setSecond(45);
    try testing.expectFmt(t2, "2009-02-13 10:15:45 UTC");

    const t3 = t2.add(.hours, 14).add(.minutes, 46).add(.seconds, 18);
    try testing.expectFmt(t3, "2009-02-14 01:02:03 UTC");

    const next_sec = t3.next(.second);
    try testing.expectFmt(next_sec, "2009-02-14 01:02:04 UTC");

    const next_min = t3.next(.minute);
    try testing.expectFmt(next_min, "2009-02-14 01:03:00 UTC");

    const next_hr = t3.next(.hour);
    try testing.expectFmt(next_hr, "2009-02-14 02:00:00 UTC");

    const next_day = t3.next(.day);
    try testing.expectFmt(next_day, "2009-02-15 00:00:00 UTC");

    const start_of_min = t3.setStartOf(.minute);
    try testing.expectFmt(start_of_min, "2009-02-14 01:02:00 UTC");

    const start_of_hr = t3.setStartOf(.hour);
    try testing.expectFmt(start_of_hr, "2009-02-14 01:00:00 UTC");

    const start_of_day = t3.setStartOf(.day);
    try testing.expectFmt(start_of_day, "2009-02-14 00:00:00 UTC");

    const start_of_month = t3.setStartOf(.month);
    try testing.expectFmt(start_of_month, "2009-02-01 00:00:00 UTC");

    const start_of_year = t3.setStartOf(.year);
    try testing.expectFmt(start_of_year, "2009-01-01 00:00:00 UTC");

    const end_of_min = t3.setEndOf(.minute);
    try testing.expectFmt(end_of_min, "2009-02-14 01:02:59 UTC");

    const end_of_hr = t3.setEndOf(.hour);
    try testing.expectFmt(end_of_hr, "2009-02-14 01:59:59 UTC");

    const end_of_day = t3.setEndOf(.day);
    try testing.expectFmt(end_of_day, "2009-02-14 23:59:59 UTC");

    const end_of_month = t3.setEndOf(.month);
    try testing.expectFmt(end_of_month, "2009-02-28 23:59:59 UTC");

    const end_of_year = t3.setEndOf(.year);
    try testing.expectFmt(end_of_year, "2009-12-31 23:59:59 UTC");

    const leap_date = Time.unix(951782400); // 2000-02-29 00:00:00
    const end_of_leap_month = leap_date.setEndOf(.month);
    try testing.expectFmt(end_of_leap_month, "2000-02-29 23:59:59 UTC");
}

test isLeapYear {
    try testing.expect(!isLeapYear(1999));
    try testing.expect(isLeapYear(2000));
    try testing.expect(isLeapYear(2004));
}

test daysInMonth {
    try testing.expectEqual(daysInMonth(1999, 2), 28);
    try testing.expectEqual(daysInMonth(2000, 2), 29);
}

test rata_to_date {
    try testing.expectEqual(rata_to_date(0), .ymd(0, 3, 1));
    try testing.expectEqual(rata_to_date(RATA_TO_UNIX), .ymd(1970, 1, 1));
}

test date_to_rata {
    try testing.expectEqual(date_to_rata(.ymd(0, 3, 1)), 0);
    try testing.expectEqual(date_to_rata(.ymd(1970, 1, 1)), RATA_TO_UNIX);
}

test "fuzz against libc" {
    const c = @cImport({
        @cInclude("stdlib.h");
        @cInclude("time.h");
    });

    var r = std.Random.DefaultPrng.init(123);
    for (0..1_000) |_| {
        // std.debug.print("it = {d}\n", .{i});
        var epoch: i64 = @intCast(r.random().int(u32));
        const dt = Time.unix(epoch).date();
        const tm = c.gmtime(&epoch).*;

        try testing.expectEqual(dt.year, @intCast(tm.tm_year + 1900));
        try testing.expectEqual(dt.month, @intCast(tm.tm_mon + 1));
        try testing.expectEqual(dt.day, @intCast(tm.tm_mday));
    }
}
