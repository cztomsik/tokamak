// private (for now)

const std = @import("std");

pub fn Buf(comptime T: type) type {
    return struct {
        buf: []T = &.{},
        len: usize = 0,

        /// Init with already existing slice
        pub fn init(buf: []T) @This() {
            return .{ .buf = buf };
        }

        /// Init in comptime (capacity needs to be known in advance)
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

        /// Remove and return last item.
        pub fn pop(self: *@This()) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buf[self.len];
        }

        /// Get current slice
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
