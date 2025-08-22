const std = @import("std");
const Element = @import("element.zig").Element;
const LocalName = @import("local_name.zig").LocalName;
const util = @import("../util.zig");
const BPTree = @import("../util/bptree.zig").BPTree;

const Key = struct {
    element: *Element, // el ptrs are stable (arena)
    attr_name: LocalName, // u128

    fn key(element: *Element, attr_name: []const u8) Key {
        return .{
            .element = element,
            .attr_name = .parse(attr_name),
        };
    }
};

pub const AttrMap = struct {
    arena: std.mem.Allocator,
    inner: BPTree(Key, util.Smol128, cmp),

    pub fn init(arena: std.mem.Allocator) !AttrMap {
        return .{
            .arena = arena,
            .inner = .empty,
        };
    }

    pub fn getAttribute(self: *AttrMap, element: *Element, name: []const u8) ?[]const u8 {
        // NOTE: Smol.str() NEEDS ptr here!!!
        return if (self.inner.getPtr(.key(element, name))) |val| val.str() else null;
    }

    pub fn setAttribute(self: *AttrMap, element: *Element, name: []const u8, value: []const u8) !void {
        const val = try util.Smol128.init(self.arena, value);
        try self.inner.put(self.arena, .key(element, name), val);
    }

    fn cmp(a: Key, b: Key) std.math.Order {
        return switch (std.math.order(@intFromPtr(a.element), @intFromPtr(b.element))) {
            // We can do this because LocalName is always inline SSO
            .eq => std.math.order(@intFromEnum(a.attr_name), @intFromEnum(b.attr_name)),
            else => |res| res,
        };
    }
};

const testing = @import("../testing.zig");

test "basic usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var attrs = try AttrMap.init(arena.allocator());

    var el1: Element = undefined;
    var el2: Element = undefined;

    try testing.expectEqual(attrs.getAttribute(&el1, "id"), null);
    try testing.expectEqual(attrs.getAttribute(&el2, "id"), null);

    try attrs.setAttribute(&el1, "id", "first");
    try testing.expectEqual(attrs.getAttribute(&el1, "id"), "first");

    try attrs.setAttribute(&el2, "id", "second");
    try testing.expectEqual(attrs.getAttribute(&el2, "id"), "second");

    try attrs.setAttribute(&el2, "id", "new");
    try testing.expectEqual(attrs.getAttribute(&el2, "id"), "new");

    // var r = std.Random.DefaultPrng.init(123);
    // for (0..1000) |i| {
    //     var buf: [32]u8 = undefined;
    //     r.random().bytes(&buf);
    //     const el = if (i % 2 == 0) &el1 else &el2;
    //     const len = if (i % buf.len == 0) 1 else i % buf.len;
    //     const val = buf[0..len];

    //     try attrs.setAttribute(
    //         el,
    //         val,
    //         val,
    //     );

    //     try testing.expectEqual(
    //         attrs.getAttribute(el, val),
    //         val,
    //     );
    // }
}
