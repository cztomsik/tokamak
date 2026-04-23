const std = @import("std");
const meta = @import("meta.zig");

pub fn collect(allocator: std.mem.Allocator, iter: anytype) ![]const IterItem(@TypeOf(iter)) {
    var copy = iter;
    var buf: std.ArrayList(IterItem(@TypeOf(copy))) = .empty;
    while (copy.next()) |it| try buf.append(allocator, it);
    return buf.toOwnedSlice(allocator);
}

fn IterItem(comptime T: type) type {
    return meta.Unwrap(meta.Result(meta.Deref(T).next));
}

test collect {
    var it = std.mem.splitSequence(u8, "hello world", " ");

    const items: []const []const u8 = try collect(std.testing.allocator, &it);
    defer std.testing.allocator.free(items);

    try std.testing.expectEqualDeep(&[_][]const u8{ "hello", "world" }, items);
}
