const std = @import("std");
const meta = @import("meta.zig");

// NOTE: I don't have a strong opinion about this (yet). I like FP but I am also
// using Zig for a reason and Zig is not an FP language and it's always going to
// be a bit awkward to do FP patterns. That said, lazy iterators are most likely
// better than collecting everything and then filtering the array list and
// freeing the unused memory, so there might be some use for this. My original
// motivation was collecting keys from a hashmap:
//
//     var iter = tk.iter.map(xxx.keyIterator(), tk.meta.deref);
//     const keys = try tk.iter.collect(agent.arena, &iter);
//
// Like I said, I'm not yet sure if it's worth it, but I decided to give it a
// try. Consider this highly experimental.

pub fn collect(allocator: std.mem.Allocator, iter: anytype) ![]const IterItem(@TypeOf(iter)) {
    const copy = iter; // TODO: I am not yet sure if we should allow passing iterators by value, but this is what makes it possible
    var buf: std.ArrayList(IterItem(@TypeOf(copy))) = .empty;
    while (if (@typeInfo(@TypeOf(copy.next())) == .error_union) try copy.next() else copy.next()) |it| try buf.append(allocator, it);
    return buf.toOwnedSlice(allocator);
}

fn IterItem(comptime Iter: type) type {
    return meta.Unwrap(meta.UnwrapErr(@TypeOf(meta.Deref(Iter).next(undefined))));
}

test IterItem {
    comptime std.debug.assert(IterItem(std.mem.SplitIterator(u8, .sequence)) == []const u8);
}

test collect {
    var it = std.mem.splitSequence(u8, "hello world", " ");

    const items: []const []const u8 = try collect(std.testing.allocator, &it);
    defer std.testing.allocator.free(items);

    try std.testing.expectEqualDeep(&[_][]const u8{ "hello", "world" }, items);
}

pub fn map(iter: anytype, comptime fun: anytype) Map(@TypeOf(iter), fun) {
    return .{ .iter = iter };
}

pub fn Map(comptime Iter: type, comptime fun: anytype) type {
    return struct {
        iter: Iter,

        pub fn next(self: *@This()) !?MapItem(IterItem(Iter), fun) {
            const it = if (@typeInfo(@TypeOf(self.iter.next())) == .error_union) try self.iter.next() else self.iter.next();
            return fun(it orelse return null);
        }
    };
}

fn MapItem(comptime Item: type, fun: anytype) type {
    return meta.Unwrap(@TypeOf(fun(@as(Item, undefined))));
}

test MapItem {
    comptime std.debug.assert(MapItem([]const u8, strlen) == usize);
}

fn strlen(str: []const u8) usize {
    return str.len;
}

test map {
    var words = std.mem.splitSequence(u8, "hello world", " ");
    var lens = map(&words, strlen);

    const items: []const usize = try collect(std.testing.allocator, &lens);
    defer std.testing.allocator.free(items);

    try std.testing.expectEqualDeep(&[_]usize{ 5, 5 }, items);
}
