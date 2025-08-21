// https://research.swtch.com/sparse
// BUT I am not 100% sure about this anymore, I wanted to use it for regex clist
// tracking so I could remove the bitset (and the ops.len <= 64 limit)
// but I don't like to waste 2 * ops.len just to save a few ticks... I think
// even 2-layer hibitset could be fast enough (and much smaller).

const std = @import("std");

pub const Sparse = struct {
    // TODO: should be [*]u32 but let's first make sure it actually works
    dense: []u32,
    sparse: []u32,
    n: u32 = 0,

    pub fn init(mem: []u32) Sparse {
        std.debug.assert(mem.len % 2 == 0);
        _ = std.valgrind.memcheck.makeMemDefined(std.mem.asBytes(&mem));

        return .{
            .dense = mem[0 .. mem.len / 2],
            .sparse = mem[mem.len / 2 ..],
        };
    }

    pub fn add(self: *Sparse, i: u32) void {
        std.debug.assert(i < self.sparse.len);
        self.sparse[i] = self.n;
        self.dense[self.n] = i;
        self.n += 1;
    }

    pub fn has(self: *Sparse, i: u32) bool {
        std.debug.assert(i < self.sparse.len);
        return self.sparse[i] < self.n and self.dense[self.sparse[i]] == i;
    }

    pub fn clear(self: *Sparse) void {
        self.n = 0;
    }
};

test {
    var buf: [32]u32 = undefined;

    var set = Sparse.init(&buf);
    try std.testing.expect(!set.has(12));

    set.add(12);
    try std.testing.expect(set.has(12));

    set.clear();
    try std.testing.expect(!set.has(12));
}
