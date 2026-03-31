const builtin = @import("builtin");
const std = @import("std");

/// A simple string type with SSO optimization. Strings up to 15 bytes are
/// stored inline, longer strings are stored as a pointer+length pair.
///
/// Discrimination is done via the LSB of the first byte: short strings set it
/// to 1, long strings leave it at 0. Both variants store the actual length
/// shifted left by 1 bit, halving the maximum representable length.
pub const String = extern union {
    short: ShortString,
    long: LongString,

    comptime {
        // 32/64-bit LE only
        std.debug.assert((@sizeOf(usize) == 4 or @sizeOf(usize) == 8) and builtin.cpu.arch.endian() == .little);
    }

    pub const empty: String = initComptime("");

    pub inline fn initComptime(comptime s: []const u8) String {
        return initShort(s) orelse initLong(s);
    }

    pub fn initShort(s: []const u8) ?String {
        return if (ShortString.init(s)) |short| .{ .short = short } else null;
    }

    fn initLong(s: []const u8) String {
        return .{ .long = .init(s) };
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
        return if (self.short.len21 & 1 == 1) .short else .long;
    }

    pub fn len(self: String) usize {
        return switch (self.kind()) {
            .short => self.short.len(),
            .long => self.long.len(),
        };
    }

    pub fn str(self: *const String) []const u8 {
        return switch (self.kind()) {
            .short => self.short.str(),
            .long => self.long.str(),
        };
    }

    pub fn format(self: *const String, writer: anytype) !void {
        try writer.writeAll(self.str());
    }

    pub fn parse(s: []const u8) !String {
        return initShort(s) orelse initLong(s);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !String {
        const s = try std.json.innerParse([]const u8, allocator, source, options);
        return initShort(s) orelse initLong(s);
    }

    pub fn jsonStringify(self: *const String, w: anytype) !void {
        try w.write(self.str());
    }

    pub fn eq(a: String, b: String) bool {
        if (a.kind() == .short and b.kind() == .short) {
            return a.short.eq(b.short);
        }

        return std.mem.eql(u8, a.str(), b.str());
    }
};

/// A string that is guaranteed to fit within 2 words (max 15 bytes of data).
/// Note that we always fully-init the struct so that we can reliably compare
/// two short strings just by value.
pub const ShortString = extern struct {
    len21: u8 = 1,
    buf: [15]u8 = @splat(0),

    pub const empty: ShortString = initComptime("");

    pub inline fn initComptime(comptime s: []const u8) ShortString {
        return comptime init(s) orelse @compileError("string too long");
    }

    pub fn init(s: []const u8) ?ShortString {
        if (s.len <= 15) {
            var res: ShortString = .{ .len21 = @intCast((s.len << 1) | 1) };
            @memcpy(res.buf[0..s.len], s);
            return res;
        } else return null;
    }

    pub fn len(self: ShortString) usize {
        return self.len21 >> 1;
    }

    pub fn str(self: *const ShortString) []const u8 {
        return self.buf[0..self.len()];
    }

    pub fn format(self: *const ShortString, writer: anytype) !void {
        try writer.writeAll(self.str());
    }

    pub fn parse(s: []const u8) !ShortString {
        return init(s) orelse error.Overflow;
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ShortString {
        const s = try std.json.innerParse([]const u8, allocator, source, options);
        return init(s) orelse error.Overflow;
    }

    pub fn jsonStringify(self: *const ShortString, w: anytype) !void {
        try w.write(self.str());
    }

    pub fn eq(a: ShortString, b: ShortString) bool {
        return @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
    }
};

const LongString = extern struct {
    len2: usize,
    ptr: [*]const u8,
    _pad: [16 - 2 * @sizeOf(usize)]u8 = @splat(0),

    fn init(s: []const u8) LongString {
        std.debug.assert(s.len <= comptime std.math.maxInt(usize) >> 1);

        return .{
            .ptr = s.ptr,
            .len2 = s.len << 1,
        };
    }

    fn len(self: LongString) usize {
        return self.len2 >> 1;
    }

    fn str(self: LongString) []const u8 {
        return self.ptr[0..self.len()];
    }
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

test "format" {
    const short: String = .initComptime("foo");
    try std.testing.expectFmt("foo", "{f}", .{short});
    try std.testing.expectFmt("foo", "{f}", .{short.short});

    const long: String = .initComptime("a longer string here");
    try std.testing.expectFmt("a longer string here", "{f}", .{long});
}

test "json" {
    const s: String = .initComptime("foo");
    try std.testing.expectFmt("\"foo\"", "{f}", .{std.json.fmt(s, .{})});

    const p = try std.json.parseFromSlice(String, std.testing.allocator, "\"foo\"", .{});
    defer p.deinit();
    try std.testing.expectEqual(s, p.value);
}
