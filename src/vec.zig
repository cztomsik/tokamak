// private (for now)

const std = @import("std");

pub fn Buf(comptime T: type) type {
    return struct {
        buf: []T = &.{},
        len: usize = 0,

        pub fn initComptime(comptime capacity: usize) @This() {
            var buf: [capacity]T = undefined;
            return .{ .buf = &buf };
        }

        pub fn push(self: *@This(), v: T) void {
            self.buf[self.len] = v;
            self.len += 1;
        }

        pub fn items(self: *@This()) []T {
            return self.buf[0..self.len];
        }

        pub fn finish(self: *@This()) []const T {
            const copy = self.buf[0..self.len].*;
            return &copy;
        }
    };
}

// TODO: The idea here was to have something which works both in runtime and
//       comptime but I am not sure about this anymore... So far it's only used
//       in tpl, but maybe it's not worth saving few lines.
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
