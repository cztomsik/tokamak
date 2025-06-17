const std = @import("std");

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

        /// Remove and return the last item.
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
