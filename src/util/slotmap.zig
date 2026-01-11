const std = @import("std");

pub fn SlotMap(comptime T: type) type {
    return struct {
        pages: []Page,

        pub const Id = packed struct(u64) {
            gen: u32,
            index: u32,
        };

        pub const Entry = struct {
            id: Id,
            value: *T,
        };

        pub const Slot = struct {
            gen: u32,
            value: T,
        };

        pub const Page = struct {
            used: u64, // bitset
            slots: [64]Slot,
        };

        pub const Iterator = struct {
            map: *SlotMap(T),
            index: u32 = 0,

            pub fn next(self: *Iterator) ?Entry {
                for (self.map.pages[(self.index / 64)..]) |*page| {
                    for ((self.index % 64)..64) |si| {
                        defer self.index += 1;

                        if (page.used & @as(u64, 1) << @as(u6, @intCast(si)) != 0) {
                            return .{
                                .id = .{
                                    .gen = page.slots[si].gen,
                                    .index = self.index,
                                },
                                .value = &page.slots[si].value,
                            };
                        }
                    }
                }

                return null;
            }
        };

        pub fn init(pages: []Page) @This() {
            for (pages) |*p| {
                p.used = 0;
                for (&p.slots) |*s| s.gen = 1;
            }

            return .{
                .pages = pages,
            };
        }

        pub fn initAlloc(allocator: std.mem.Allocator, n_pages: usize) !@This() {
            return init(
                try allocator.alloc(Page, n_pages),
            );
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.pages);
        }

        pub fn insert(self: *@This(), value: T) !Id {
            const entry = try self.insertEntry();
            entry.value.* = value;
            return entry.id;
        }

        pub fn insertEntry(self: *@This()) !Entry {
            for (self.pages, 0..) |*p, pi| {
                // Skip full
                if (p.used == ~@as(u64, 0)) continue;

                for (0..64) |si| {
                    const mask = @as(u64, 1) << @as(u6, @intCast(si));

                    // Check if slot is free and not exhausted (gen != 0)
                    if (p.used & mask == 0 and p.slots[si].gen != 0) {
                        p.used |= mask;

                        return .{
                            .id = .{
                                .gen = p.slots[si].gen,
                                .index = @intCast(pi * 64 + si),
                            },
                            .value = &p.slots[si].value,
                        };
                    }
                }
            } else return error.Overflow;
        }

        pub fn find(self: *@This(), id: Id) ?*T {
            if (self.findSlot(id.index)) |slot| {
                if (slot.gen == id.gen) {
                    return &slot.value;
                }
            }

            return null;
        }

        pub fn remove(self: *@This(), id: Id) void {
            if (self.findSlot(id.index)) |slot| {
                if (slot.gen == id.gen) {
                    self.pages[id.index / 64].used &= ~@as(u64, 1) << @as(u6, @intCast(id.index % 64));
                    slot.gen +%= 1; // overflow to zero means the slot is exhausted and can't be used anymore
                }
            }
        }

        pub fn iter(self: *@This()) Iterator {
            return Iterator{
                .map = self,
            };
        }

        pub fn len(self: *const @This()) usize {
            var count: usize = 0;
            for (self.pages) |p| count += @popCount(p.used);
            return count;
        }

        fn findSlot(self: *@This(), index: u32) ?*Slot {
            const page = index / 64;
            const slot = index % 64;

            if (page < self.pages.len) {
                const mask = @as(u64, 1) << @as(u6, @intCast(slot));

                if (self.pages[page].used & mask != 0) {
                    return &self.pages[page].slots[slot];
                }
            }

            return null;
        }
    };
}

test SlotMap {
    var buf: [2]SlotMap(usize).Page = undefined;
    var map = SlotMap(usize).init(&buf);

    const id = try map.insert(123);
    try std.testing.expectEqual(123, map.find(id).?.*);
    try std.testing.expectEqual(1, map.len());

    map.remove(id);
    try std.testing.expectEqual(null, map.find(id));

    for (0..128) |i| {
        const id2 = try map.insert(i);
        try std.testing.expectEqual(i, map.find(id2).?.*);
    }

    var it = map.iter();
    var j: usize = 0;
    while (it.next()) |entry| : (j += 1) {
        try std.testing.expectEqual(j, entry.value.*);
    }

    try std.testing.expectEqual(128, map.len());
    try std.testing.expectError(error.Overflow, map.insert(128));

    // Check paging in remove()
    const last: @TypeOf(map).Id = .{ .gen = map.findSlot(127).?.gen, .index = 127 };
    map.remove(last);
    try std.testing.expectEqual(null, map.find(id));
}

test "iterator" {
    var buf: [2]SlotMap(usize).Page = undefined;
    var map = SlotMap(usize).init(&buf);

    // Fill first page completely, then add 2 more items
    for (0..66) |i| _ = try map.insert(i);

    // Check iter
    var it = map.iter();
    for (0..66) |i| try std.testing.expectEqual(i, it.next().?.value.*);
    try std.testing.expectEqual(null, it.next());

    // Remove all from the first page (2 items left in the second page)
    for (0..64) |i| map.remove(.{ .gen = map.findSlot(@intCast(i)).?.gen, .index = @intCast(i) });
    try std.testing.expectEqual(2, map.len());

    // Find both items
    it = map.iter();
    try std.testing.expectEqual(64, it.next().?.value.*);
    try std.testing.expectEqual(65, it.next().?.value.*);
    try std.testing.expectEqual(null, it.next());
}
