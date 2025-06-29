const std = @import("std");

pub const Smol128 = SmolStr(u128);
pub const Smol192 = SmolStr(u192);
pub const Smol256 = SmolStr(u256);

// TODO: configurable len type? But the total max length should probably be
//       validated at call-site anyway - it's domain-specific and not worth all
//       the extra code generated.
pub fn SmolStr(comptime B: type) type {
    std.debug.assert(@sizeOf(B) >= 2 * @sizeOf(usize));
    std.debug.assert(@sizeOf(B) < 127);

    const N = (@bitSizeOf(B) / 8) - 4; // @sizeOf(u192) > 24
    const P = std.meta.Int(.unsigned, @bitSizeOf(B) - @bitSizeOf(usize) - @bitSizeOf(u32));

    // Inspired by https://cedardb.com/blog/german_strings/ but we don't tag pointers.
    // NOTE: we also ZERO-OUT buf/padding so we can then RELIABLY compare by value.
    //
    // Layout:
    //   raw   [....u128/u192/xxx....]
    //   short [........buf][len: u32]
    //   long  [ptr][...pad][len: u32]
    return packed union {
        raw: B, // u128, u192, ...
        short: packed struct {
            buf: std.meta.Int(.unsigned, 8 * N) = 0, // ZERO!
            len: u32,
        },
        long: packed struct {
            ptr: [*]const u8,
            // TODO: endianness?
            padding: P = 0, // ZERO!
            len: u32,
        },

        const Self = @This();

        pub const empty: Self = .{ .short = .{ .len = 0 } };

        pub fn init(allocator: std.mem.Allocator, s: []const u8) !Self {
            return initShort(s) orelse .{
                .long = .{
                    .len = @intCast(s.len),
                    .ptr = (try allocator.dupe(u8, s)).ptr,
                },
            };
        }

        pub fn initShort(s: []const u8) ?Self {
            if (s.len <= N) {
                var res: Self = .{ .short = .{ .len = @intCast(s.len) } };
                @memcpy(@as([*]u8, @ptrCast(&res.short.buf)), s);
                return res;
            } else return null;
        }

        pub fn initComptime(s: []const u8) Self {
            return initShort(s) orelse .{
                .long = .{
                    .len = @intCast(s.len),
                    .ptr = s.ptr,
                },
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.kind() == .long) {
                allocator.free(self.str());
            }
        }

        pub fn kind(self: Self) enum { short, long } {
            return if (self.short.len <= N) .short else .long;
        }

        pub fn len(self: Self) usize {
            return self.short.len;
        }

        pub fn str(self: *const Self) []const u8 {
            return switch (self.kind()) {
                .short => @as([*]const u8, @ptrCast(&self.short.buf))[0..self.short.len],
                .long => self.long.ptr[0..self.long.len],
            };
        }

        pub fn eq(a: Self, b: Self) bool {
            if (a.kind() == .short and b.kind() == .short) {
                return a == b;
            }

            return std.mem.eql(u8, a.str(), b.str());
        }
    };
}

test "comptime" {
    // u128 - u32 -> 12 bytes left
    const s1 = Smol128.initComptime("sm128");
    try std.testing.expectEqual(5, s1.len());
    try std.testing.expectEqualStrings("sm128", s1.str());

    const s2 = Smol128.initComptime("long comptime str");
    try std.testing.expectEqual(17, s2.len());
    try std.testing.expectEqualStrings("long comptime str", s2.str());

    // u192 - u32 -> 20 bytes left
    const s3 = Smol192.initComptime("sm192");
    try std.testing.expectEqual(5, s3.len());
    try std.testing.expectEqualStrings("sm192", s3.str());

    const s4 = Smol192.initComptime("even longer comptime str");
    try std.testing.expectEqual(24, s4.len());
    try std.testing.expectEqualStrings("even longer comptime str", s4.str());
}

test "short" {
    // u128 - u32 -> 12 bytes left
    const s1 = Smol128.initShort("foo").?;
    try std.testing.expectEqual(3, s1.len());
    try std.testing.expectEqualStrings("foo", s1.str());

    try std.testing.expect(Smol128.initShort("twelve bytes") != null);
    try std.testing.expect(Smol128.initShort("> twelve bytes") == null);

    // u192 - u32 -> 20 bytes left
    const s3 = Smol192.initShort("foo").?;
    try std.testing.expectEqual(3, s3.len());
    try std.testing.expectEqualStrings("foo", s3.str());

    try std.testing.expect(Smol192.initShort("twenty bytes can fit") != null);
    try std.testing.expect(Smol192.initShort("> twenty b should not") == null);
}

test "long/auto" {
    // u128 - u32 -> 12 bytes left
    var s1 = try Smol128.init(std.testing.allocator, "very long string");
    defer s1.deinit(std.testing.allocator);

    try std.testing.expectEqual(16, s1.len());
    try std.testing.expectEqualStrings("very long string", s1.str());
}
