const std = @import("std");

pub const Buf = @import("util/buf.zig").Buf;
pub const SlotMap = @import("util/slotmap.zig").SlotMap;
pub const SmolStr = @import("util/smolstr.zig").SmolStr;
pub const Smol128 = @import("util/smolstr.zig").Smol128;
pub const Smol192 = @import("util/smolstr.zig").Smol192;
pub const Smol256 = @import("util/smolstr.zig").Smol256;
pub const Sparse = @import("util/sparse.zig").Sparse;

pub const whitespace = std.ascii.whitespace;

pub fn trim(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, &whitespace);
}

pub fn truncateEnd(text: []const u8, width: usize) []const u8 {
    return if (text.len <= width) text else text[text.len - width ..];
}

pub fn truncateStart(text: []const u8, width: usize) []const u8 {
    return if (text.len <= width) text else text[0..width];
}

pub fn countScalar(comptime T: type, slice: []const T, value: T) usize {
    var n: usize = 0;
    for (slice) |c| {
        if (c == value) n += 1;
    }
    return n;
}

pub fn Cmp(comptime T: type) type {
    return struct {
        // TODO: can we somehow flatten the anytype?
        // pub const cmp = if (std.meta.hasMethod(T, "cmp")) T.cmp else std.math.order;

        pub fn cmp(a: T, b: T) std.math.Order {
            if (std.meta.hasMethod(T, "cmp")) {
                return a.cmp(b);
            }

            return std.math.order(a, b);
        }

        pub fn lt(a: T, b: T) bool {
            return @This().cmp(a, b) == .lt;
        }

        pub fn eq(a: T, b: T) bool {
            return @This().cmp(a, b) == .eq;
        }

        pub fn gt(a: T, b: T) bool {
            return @This().cmp(a, b) == .gt;
        }
    };
}

pub fn cmp(a: anytype, b: @TypeOf(a)) std.math.Order {
    return Cmp(@TypeOf(a)).cmp(a, b);
}

pub fn lt(a: anytype, b: @TypeOf(a)) bool {
    return Cmp(@TypeOf(a)).lt(a, b);
}

pub fn eq(a: anytype, b: @TypeOf(a)) bool {
    return Cmp(@TypeOf(a)).eq(a, b);
}

pub fn gt(a: anytype, b: @TypeOf(a)) bool {
    return Cmp(@TypeOf(a)).gt(a, b);
}

test {
    try std.testing.expect(lt(1, 2));
    try std.testing.expect(eq(2, 2));
    try std.testing.expect(gt(2, 1));
}
