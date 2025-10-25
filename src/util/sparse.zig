const std = @import("std");

// https://research.swtch.com/sparse
// NOTE: It was not immediately obvious (to me) that both indices can be of a
//       different type and that the sparse list can be also used for iteration.
//       The total mem usage depends on higher-bounds of both types, ie. even
//       if the `Sparse` type is something like u16, the mem usage is still
//       reasonable, as long as the upper-bound of items in the set is known
//       to be low.
pub fn Sparse(comptime S: type, comptime D: type) type {
    return struct {
        sparse: []D,
        dense: []S,
        len: D = 0,

        pub fn init(sparse: []D, dense: []S) @This() {
            _ = std.valgrind.memcheck.makeMemDefined(std.mem.asBytes(&sparse));

            return .{
                .sparse = sparse,
                .dense = dense,
            };
        }

        pub fn add(self: *@This(), i: S) void {
            std.debug.assert(i < self.sparse.len);
            if (self.has(i)) return;
            self.sparse[i] = self.len;
            self.dense[self.len] = i;
            self.len += 1;
        }

        pub fn has(self: *@This(), i: S) bool {
            std.debug.assert(i < self.sparse.len);
            return self.sparse[i] < self.len and self.dense[self.sparse[i]] == i;
        }

        pub fn clear(self: *@This()) void {
            self.len = 0;
        }
    };
}

test {
    var buf: [32]u32 = undefined;

    var set = Sparse(u32, u32).init(buf[0..16], buf[16..]);
    try std.testing.expect(!set.has(12));

    set.add(12);
    try std.testing.expect(set.has(12));

    set.clear();
    try std.testing.expect(!set.has(12));
}
