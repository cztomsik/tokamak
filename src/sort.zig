const std = @import("std");

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
