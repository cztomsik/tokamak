const builtin = @import("builtin");
const std = @import("std");

/// A simple string type with SSO optimization. Strings up to 15 bytes are
/// stored inline, longer strings are stored as a pointer+length pair.
///
/// Discrimination is done via the `head` byte at offset 15, which overlaps
/// with the MSB of the `ptr` field. On 64-bit little-endian systems, userspace
/// pointers only use 48-57 bits of address space, so the MSB is always 0.
/// Short strings store `len + 1` in `head` (range 1-16), which is never 0.
///
///     Byte: 0                                                15
///     Short [buf: string data, zero-padded ...........] [len+1]
///     Long  [len: usize       ] [ptr: [*]u8                  0]
pub const String = extern union {
    short: ShortString,
    long: LongString,

    comptime {
        // 64-bit LE only
        std.debug.assert(@sizeOf(usize) == 8 and builtin.cpu.arch.endian() == .little);
    }

    pub const empty: String = initComptime("");

    pub inline fn initComptime(comptime s: []const u8) String {
        return initShort(s) orelse initLong(s);
    }

    pub fn initShort(s: []const u8) ?String {
        return if (ShortString.init(s)) |short| .{ .short = short } else null;
    }

    fn initLong(s: []const u8) String {
        return .{
            .long = .{
                .ptr = s.ptr,
                .len = @intCast(s.len),
            },
        };
    }

    pub fn dupe(gpa: std.mem.Allocator, s: []const u8) !String {
        return initShort(s) orelse initLong(try gpa.dupe(u8, s));
    }

    pub fn free(self: *String, gpa: std.mem.Allocator) void {
        if (self.kind() == .long) {
            gpa.free(self.str());
        }
    }

    pub fn kind(self: String) enum { short, long } {
        return if (self.short.head == 0) .long else .short;
    }

    pub fn len(self: String) usize {
        return switch (self.kind()) {
            .short => self.short.len(),
            .long => self.long.len,
        };
    }

    pub fn str(self: *const String) []const u8 {
        return switch (self.kind()) {
            .short => self.short.str(),
            .long => self.long.ptr[0..self.long.len],
        };
    }

    pub fn eq(a: String, b: String) bool {
        if (a.kind() == .short and b.kind() == .short) {
            return a.short.eq(b.short);
        }

        return std.mem.eql(u8, a.str(), b.str());
    }
};

/// A string that is guaranteed to fit within 2 words (max 15 bytes of data).
pub const ShortString = extern struct {
    buf: [15]u8 = [_]u8{0} ** 15,
    head: u8 = 0,

    pub const empty: ShortString = initComptime("");

    pub inline fn initComptime(comptime s: []const u8) ShortString {
        return comptime init(s) orelse @compileError("string too long");
    }

    pub fn init(s: []const u8) ?ShortString {
        if (s.len <= 15) {
            var res: ShortString = .{ .head = @intCast(s.len + 1) };
            @memcpy(res.buf[0..s.len], s);
            return res;
        } else return null;
    }

    pub fn len(self: ShortString) usize {
        return self.head -| 1;
    }

    pub fn str(self: *const ShortString) []const u8 {
        return self.buf[0..self.len()];
    }

    pub fn eq(a: ShortString, b: ShortString) bool {
        return @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
    }
};

const LongString = extern struct {
    len: usize,
    ptr: [*]const u8,
};

comptime {
    std.debug.assert(@sizeOf(String) == 16);
}

test "comptime" {
    const s1: String = .initComptime("foo");
    try std.testing.expectEqual(3, s1.len());
    try std.testing.expectEqualStrings("foo", s1.str());

    const s2: String = .initComptime("long comptime string");
    try std.testing.expectEqual(20, s2.len());
    try std.testing.expectEqualStrings("long comptime string", s2.str());
}

test "short" {
    const s1 = String.initShort("foo").?;
    try std.testing.expectEqual(3, s1.len());
    try std.testing.expectEqualStrings("foo", s1.str());

    // 16 bytes total, 1 byte for head -> 15 bytes for string data
    try std.testing.expect(String.initShort("15 bytes fit ok") != null);
    try std.testing.expect(String.initShort("> 15 bytes should not") == null);
}

test "dupe" {
    var s1 = try String.dupe(std.testing.failing_allocator, "a short string");
    defer s1.free(std.testing.failing_allocator);

    var s2 = try String.dupe(std.testing.allocator, "a bit longer string");
    defer s2.free(std.testing.allocator);

    try std.testing.expectEqual(14, s1.len());
    try std.testing.expectEqualStrings("a short string", s1.str());

    try std.testing.expectEqual(19, s2.len());
    try std.testing.expectEqualStrings("a bit longer string", s2.str());
}

test "eq" {
    try std.testing.expect(String.eq(.initComptime("a"), .initComptime("a")));
    try std.testing.expect(!String.eq(.initComptime("a"), .initComptime("b")));
}
