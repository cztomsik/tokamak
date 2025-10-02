// The original motivation for this is long gone so IDK...
// But it might be still useful as arena-friendly hashmap alternative
// https://www.cs.usfca.edu/~galles/visualization/BPlusTree.html

const std = @import("std");

pub fn BPTree(comptime K: type, comptime V: type, comptime cmp: fn (K, K) std.math.Order) type {
    const max_branch = 8;
    const max_leaf = 8;
    comptime std.debug.assert(max_branch % 2 == 0 and max_leaf % 2 == 0);

    return struct {
        root: ?*Node = null,

        pub const empty: @This() = .{};

        const Error = std.mem.Allocator.Error;

        const Node = struct {
            kind: enum { branch, leaf },

            inline fn as(self: *Node, comptime T: type) *T {
                return @alignCast(@fieldParentPtr("node", self));
            }

            fn insert(self: *Node, allocator: std.mem.Allocator, key: K, value: V) Error!InsertRes {
                return switch (self.kind) {
                    .branch => self.as(Branch).insert(allocator, key, value),
                    .leaf => self.as(Leaf).insert(allocator, key, value),
                };
            }

            inline fn key0(self: *Node) K {
                return switch (self.kind) {
                    .branch => self.as(Branch).keys[0],
                    .leaf => self.as(Leaf).keys[0],
                };
            }
        };

        const Branch = struct {
            node: Node = .{ .kind = .branch },
            keys: [max_branch]K = undefined,
            children: [max_branch + 1]*Node = undefined,
            count: usize, // KEY count

            fn insert(self: *Branch, allocator: std.mem.Allocator, key: K, value: V) Error!InsertRes {
                var i: usize = 0;
                while (i < self.count and cmp(key, self.keys[i]) != .lt) : (i += 1) {}
                const child = self.children[i];

                return switch (try child.insert(allocator, key, value)) {
                    .split => |new| insertKey(self, allocator, new.key0(), new),
                    else => |res| res,
                };
            }

            fn insertKey(self: *Branch, allocator: std.mem.Allocator, key: K, child: *Node) Error!InsertRes {
                if (self.count == max_branch) {
                    return self.splitInsert(allocator, key, child);
                }

                var i: usize = 0;
                while (i < self.count and cmp(key, self.keys[i]) == .gt) : (i += 1) {}

                if (i < self.count) {
                    std.mem.copyBackwards(K, self.keys[i + 1 .. self.count + 1], self.keys[i..self.count]);
                    std.mem.copyBackwards(*Node, self.children[i + 2 .. self.count + 2], self.children[i + 1 .. self.count + 1]);
                }

                self.keys[i] = key;
                self.children[i + 1] = child;
                self.count += 1;
                return .inserted;
            }

            fn splitInsert(self: *Branch, allocator: std.mem.Allocator, key: K, child: *Node) !InsertRes {
                const half = max_branch / 2;
                std.debug.assert(self.count == max_branch);
                self.count = half;

                const new_branch = try allocator.create(Branch);
                new_branch.* = .{ .count = half };
                new_branch.keys[0..half].* = self.keys[half..max_branch].*;
                new_branch.children[0 .. half + 1].* = self.children[half .. max_branch + 1].*;

                _ = insertKey(
                    if (cmp(key, new_branch.keys[0]) == .lt) self else new_branch,
                    allocator,
                    key,
                    child,
                ) catch {};

                return .{
                    .split = &new_branch.node,
                };
            }
        };

        const Leaf = struct {
            node: Node = .{ .kind = .leaf },
            keys: [max_leaf]K = undefined,
            values: [max_leaf]V = undefined,
            count: usize = 0, // KV count

            fn insert(self: *Leaf, allocator: std.mem.Allocator, key: K, value: V) Error!InsertRes {
                if (self.count == max_leaf) {
                    return self.splitInsert(allocator, key, value);
                }

                var i: usize = 0;
                while (i < self.count and cmp(key, self.keys[i]) == .gt) : (i += 1) {}

                if (i < self.count and cmp(key, self.keys[i]) == .eq) {
                    self.values[i] = value;
                    return .replaced;
                }

                if (i < self.count) {
                    std.mem.copyBackwards(K, self.keys[i + 1 .. self.count + 1], self.keys[i..self.count]);
                    std.mem.copyBackwards(V, self.values[i + 1 .. self.count + 1], self.values[i..self.count]);
                }

                self.keys[i] = key;
                self.values[i] = value;
                self.count += 1;
                return .inserted;
            }

            fn splitInsert(self: *Leaf, allocator: std.mem.Allocator, key: K, value: V) !InsertRes {
                const half = max_leaf / 2;
                std.debug.assert(self.count == max_leaf);
                self.count = half;

                const new_leaf = try allocator.create(Leaf);
                new_leaf.* = .{};
                new_leaf.count = half;
                new_leaf.keys[0..half].* = self.keys[half..max_leaf].*;
                new_leaf.values[0..half].* = self.values[half..max_leaf].*;

                _ = insert(
                    if (cmp(key, new_leaf.keys[0]) == .lt) self else new_leaf,
                    allocator,
                    key,
                    value,
                ) catch {};

                return .{
                    .split = &new_leaf.node,
                };
            }
        };

        const InsertRes = union(enum) {
            inserted,
            replaced,
            split: *Node,
        };

        pub fn get(self: *@This(), key: K) ?V {
            return if (self.getPtr(key)) |ptr| ptr.* else null;
        }

        pub fn getPtr(self: *@This(), key: K) ?*V {
            var node = self.root orelse return null;

            while (node.kind == .branch) {
                const branch = node.as(Branch);

                var i: usize = 0;
                while (i < branch.count and cmp(key, branch.keys[i]) != .lt) : (i += 1) {}

                node = branch.children[i];
            }

            const leaf: *Leaf = node.as(Leaf);

            var i: usize = 0;
            while (i < leaf.count and cmp(key, leaf.keys[i]) == .gt) : (i += 1) {}

            return if (i < leaf.count and cmp(key, leaf.keys[i]) == .eq) &leaf.values[i] else null;
        }

        pub fn put(self: *@This(), allocator: std.mem.Allocator, key: K, value: V) !void {
            const root = self.root orelse blk: {
                const leaf = try allocator.create(Leaf);
                leaf.* = .{};
                self.root = &leaf.node;
                break :blk &leaf.node;
            };

            switch (try root.insert(allocator, key, value)) {
                else => {},
                .split => |new| {
                    const branch = try allocator.create(Branch);
                    branch.* = .{ .count = 1 };
                    branch.keys[0] = new.key0();
                    branch.children[0] = root;
                    branch.children[1] = new;
                    self.root = &branch.node;
                },
            }
        }

        pub fn dump(self: *@This()) void {
            var w = std.fs.File.stderr().writer(&.{});
            w.interface.writeAll("\n\n") catch {};
            dumpNode(self.root.?, &w.interface, 0) catch {};
            w.interface.flush() catch {};
        }

        fn dumpNode(node: *Node, writer: *std.io.Writer, depth: usize) !void {
            try writer.splatBytesAll("  ", depth);

            switch (node.kind) {
                .branch => {
                    const branch = node.as(Branch);
                    try writer.print("Branch[{}]", .{branch.count});
                    if (branch.count > 0) {
                        try writer.print(": ", .{});
                        for (0..branch.count) |i| {
                            if (i > 0) try writer.print(" | ", .{});
                            try writer.print("{}", .{branch.keys[i]});
                        }
                    }
                    try writer.writeByte('\n');

                    for (0..branch.count + 1) |i| {
                        try dumpNode(branch.children[i], writer, depth + 1);
                    }
                },
                .leaf => {
                    const leaf = node.as(Leaf);
                    try writer.print("Leaf[{}]", .{leaf.count});
                    if (leaf.count > 0) {
                        try writer.print(": ", .{});
                        for (0..leaf.count) |i| {
                            if (i > 0) try writer.print(", ", .{});
                            try writer.print("{}={}", .{ leaf.keys[i], leaf.values[i] });
                        }
                    }
                    try writer.writeByte('\n');
                },
            }
        }
    };
}

const testing = @import("../testing.zig");

const TestTree = BPTree(usize, usize, struct {
    fn cmp(a: usize, b: usize) std.math.Order {
        return std.math.order(a, b);
    }
}.cmp);

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tree: TestTree = .empty;

    for (1..17, 100..) |k, v| {
        // std.debug.print("k={} v={}\n", .{ k, v });

        try tree.put(arena.allocator(), k, v);
        tree.dump();

        try std.testing.expectEqual(v, tree.get(k).?);
    }
}

test "random" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tree: TestTree = .empty;

    var r = std.Random.DefaultPrng.init(123);
    // for (0..10_000_000) |_| {
    for (0..1_000) |_| {
        const k = r.random().int(u32);
        const v = r.random().int(u32);

        // std.debug.print("k={} v={}\n", .{ k, v });

        try tree.put(arena.allocator(), k, v);
        try std.testing.expectEqual(v, tree.get(k).?);
    }
}
