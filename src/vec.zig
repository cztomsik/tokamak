// private (for now)

const std = @import("std");

pub fn Vec(comptime T: type) type {
    return struct {
        buf: []T = &.{},
        i: usize = 0,

        pub fn initCapacity(allocator: std.mem.Allocator, len: usize) !@This() {
            if (@inComptime()) {
                var buf: [len]T = undefined;
                return .{ .buf = &buf };
            }

            return .{
                .buf = try allocator.alloc(T, len),
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (!@inComptime()) allocator.free(self.buf);
        }

        pub fn push(self: *@This(), v: T) void {
            self.buf[self.i] = v;
            self.i += 1;
        }

        pub fn pop(self: *@This()) ?T {
            if (self.i == 0) return null;
            self.i -= 1;
            return self.buf[self.i];
        }

        pub fn finish(self: *@This()) []const T {
            std.debug.assert(self.i == self.buf.len);

            if (@inComptime()) {
                const copy = self.buf[0..self.buf.len].*;
                return &copy;
            }

            return self.buf;
        }
    };
}
