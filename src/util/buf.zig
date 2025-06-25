const std = @import("std");

// This is useful mostly for parsing - it's a simple, slice-backed container
// that is not supposed to grow beyong its max size. It does not do any bounds
// checking, except maybe the peek/pop() which returns optional.
//
// The general pattern is that you do two passes over the input, first time you
// count the max len, without any need for allocation and then, in the second
// pass you use a previously created Buf(T) to build the result.
//
// A nice touch is that it can be used in comptime, and it provides finish()
// which also checks if the final size is the same.
pub fn Buf(comptime T: type) type {
    return struct {
        buf: []T = &.{},
        len: usize = 0,

        /// Init with an already existing slice
        pub fn init(buf: []T) @This() {
            return .{ .buf = buf };
        }

        /// Init at comptime (capacity needs to be known in advance)
        pub fn initComptime(comptime capacity: usize) @This() {
            var buf: [capacity]T = undefined;
            return .{ .buf = &buf };
        }

        /// Init with newly created slice
        pub fn initAlloc(allocator: std.mem.Allocator, capacity: usize) !@This() {
            const buf = try allocator.alloc(T, capacity);
            return .{ .buf = buf };
        }

        /// Deinit (runtime-only)
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }

        /// Insert one item at the end.
        pub fn push(self: *@This(), v: T) void {
            self.buf[self.len] = v;
            self.len += 1;
        }

        /// Return the last item, if there is any.
        pub fn peek(self: *@This()) ?T {
            if (self.len == 0) return null;
            return self.buf[self.len - 1];
        }

        /// Remove and return the last item, if there is any.
        pub fn pop(self: *@This()) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buf[self.len];
        }

        pub fn insert(self: *@This(), index: usize, item: T) void {
            self.insertSlice(index, &.{item});
        }

        pub fn insertSlice(self: *@This(), index: usize, slice: []const T) void {
            std.debug.assert(index < self.len);
            std.debug.assert(self.buf.len >= self.len + slice.len);

            std.mem.copyBackwards(T, self.buf[index + slice.len ..], self.items()[index..]);
            @memcpy(self.buf[index .. index + slice.len], slice);
            self.len += slice.len;
        }

        /// Get the current slice
        pub fn items(self: *@This()) []T {
            return self.buf[0..self.len];
        }

        /// Return the final result
        pub fn finish(self: *@This()) []const T {
            if (@inComptime()) {
                const copy = self.buf[0..self.len].*;
                return &copy;
            } else {
                std.debug.assert(self.len == self.buf.len);
                return self.items();
            }
        }
    };
}

test Buf {
    var buf = try Buf(u8).initAlloc(std.testing.allocator, 7);
    defer buf.deinit(std.testing.allocator);

    buf.push(0);
    buf.insertSlice(0, &.{ 1, 2 });
    buf.push(3);
    buf.insertSlice(buf.len - 1, &.{ 4, 5 });
    buf.insert(2, 6);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 6, 0, 4, 5, 3 }, buf.items());
}
