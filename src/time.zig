// https://www.youtube.com/watch?v=0s9F4QWAl-E
// https://howardhinnant.github.io/date_algorithms.html
// https://en.wikipedia.org/wiki/Rata_Die
const std = @import("std");

const RATA_TO_UNIX = 719468;

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

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
};

pub const Time = struct {
    epoch: i64,

    pub fn unix(epoch: i64) Time {
        return .{ .epoch = epoch };
    }

    pub fn now() Time {
        return unix(std.time.timestamp());
    }

    pub fn second(self: Time) u32 {
        return @intCast(@mod(self.n(.seconds), 60));
    }

    pub fn minute(self: Time) u32 {
        return @intCast(@mod(self.n(.minutes), 60));
    }

    pub fn hour(self: Time) u32 {
        return @intCast(@mod(self.n(.hours), 24));
    }

    pub fn date(self: Time) Date {
        return rata_to_date(@divTrunc(self.epoch, std.time.s_per_day) + RATA_TO_UNIX);
    }

    fn n(self: Time, part: enum { seconds, minutes, hours }) i64 {
        return switch (part) {
            .seconds => self.epoch,
            .minutes => @divTrunc(self.epoch, std.time.s_per_min),
            .hours => @divTrunc(self.epoch, std.time.s_per_hour),
        };
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
    const y_star: i32 = @intCast(quotient(1461 * Y, 4) - C + quotient(C, 4));
    const m_star: u32 = (153 * M - 457) / 5;

    return y_star + @as(i32, @intCast(m_star)) + @as(i32, @intCast(D));
}

fn quotient(n: i64, d: u32) i64 {
    return if (n >= 0) @divTrunc(n, d) else @divTrunc((n + 1), d) - 1;
}

fn remainder(n: i64, d: u32) u32 {
    return @intCast(if (n >= 0) @mod(n, d) else (n + d) - d * quotient((n + d), d));
}

const testing = @import("testing.zig");

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
