const std = @import("std");

pub fn countScalar(comptime T: type, slice: []const T, value: T) usize {
    var n: usize = 0;
    for (slice) |c| {
        if (c == value) n += 1;
    }
    return n;
}
