const std = @import("std");

pub const Buf = @import("util/buf.zig").Buf;
pub const Shm = @import("util/shm.zig").Shm;
pub const ShmMutex = @import("util/shm.zig").Mutex;
pub const SlotMap = @import("util/slotmap.zig").SlotMap;
pub const Sparse = @import("util/sparse.zig").Sparse;

pub const whitespace = std.ascii.whitespace;

pub fn trim(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, &whitespace);
}

pub fn truncateEnd(text: []const u8, width: usize) []const u8 {
    return if (text.len <= width) text else text[text.len - width ..];
}

pub fn truncateStart(text: []const u8, width: usize) []const u8 {
    return if (text.len <= width) text else text[0..width];
}

pub fn split2(str: []const u8, delim: []const u8) struct { []const u8, []const u8 } {
    var it = std.mem.splitSequence(u8, str, delim);
    const head = it.next() orelse return .{ str, "" };
    return .{ head, it.rest() };
}

test split2 {
    try std.testing.expectEqualDeep(.{ "", "" }, split2("", " "));
    try std.testing.expectEqualDeep(.{ "hello", "" }, split2("hello", " "));
    try std.testing.expectEqualDeep(.{ "hello", "world" }, split2("hello world", " "));
}

pub fn wordWrap(str: []const u8, max_width: usize) WordWrapIterator {
    return .{
        .inner = std.unicode.Utf8View.initUnchecked(str).iterator(),
        .max_width = max_width,
    };
}

// TODO: wcwidth(), wcswidth() but we're likely going to need real grapheme
// cluster segmentation anyway because we should wrap at word boundaries.
// it looks like it's not font-specific, but **it is** term specific :-/
// https://github.com/ratatui/ratatui/discussions/1438
pub const WordWrapIterator = struct {
    inner: std.unicode.Utf8Iterator,
    max_width: usize,
    col: usize = 0,

    pub fn next(self: *WordWrapIterator) ?[]const u8 {
        const start = self.inner.i;

        while (self.inner.nextCodepointSlice()) |s| {
            self.col += 1;

            if (s.len == 1 and s[0] == '\n') {
                self.col = 0;
                return self.inner.bytes[start .. self.inner.i - 1];
            }

            if (self.col == self.max_width) {
                const line = self.inner.bytes[start..self.inner.i];
                const rest = self.inner.bytes[self.inner.i..];
                self.col = 0;
                // Skip only the first whitespace character at the boundary
                // to preserve additional whitespace for the next line.
                self.inner.bytes = if (rest.len > 0 and std.ascii.isWhitespace(rest[0])) rest[1..] else rest;
                self.inner.i = 0;
                return line;
            }
        } else return if (start < self.inner.bytes.len) self.inner.bytes[start..self.inner.i] else null;
    }
};

fn expectWrap(input: []const u8, max_width: usize, expected: []const []const u8) !void {
    var it = wordWrap(input, max_width);
    for (expected) |exp| {
        const actual = it.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(exp, actual);
    } else if (it.next()) |_| return error.TestUnexpectedResult;
}

test wordWrap {
    try expectWrap("hello world", 5, &.{ "hello", "world" });
    try expectWrap("hello\nworld", 10, &.{ "hello", "world" });
    try expectWrap("hello\n", 10, &.{"hello"});
    try expectWrap("hello world", 5, &.{ "hello", "world" });
    try expectWrap("😀😀😀", 2, &.{ "😀😀", "😀" });

    // TODO: word-boundaries, preserve indentation?
    try expectWrap("a\n\nb", 80, &.{ "a", "", "b" });
    try expectWrap("hi there", 5, &.{ "hi th", "ere" });
    try expectWrap("hello  world", 5, &.{ "hello", " worl", "d" });
    try expectWrap("   ", 3, &.{"   "});
}

pub fn countLines(str: []const u8, max_width: usize) usize {
    var it = wordWrap(str, max_width);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

test countLines {
    try std.testing.expectEqual(1, countLines("hello", 10));
    try std.testing.expectEqual(2, countLines("hello\nworld", 10));
}

pub fn countScalar(comptime T: type, slice: []const T, value: T) usize {
    var n: usize = 0;
    for (slice) |c| {
        if (c == value) n += 1;
    }
    return n;
}

pub fn Cmp(comptime T: type) type {
    return struct {
        // TODO: can we somehow flatten the anytype?
        // pub const cmp = if (std.meta.hasMethod(T, "cmp")) T.cmp else std.math.order;

        pub fn cmp(a: T, b: T) std.math.Order {
            if (std.meta.hasMethod(T, "cmp")) {
                return a.cmp(b);
            }

            return std.math.order(a, b);
        }

        pub fn lt(a: T, b: T) bool {
            return @This().cmp(a, b) == .lt;
        }

        pub fn eq(a: T, b: T) bool {
            return @This().cmp(a, b) == .eq;
        }

        pub fn gt(a: T, b: T) bool {
            return @This().cmp(a, b) == .gt;
        }
    };
}

pub fn cmp(a: anytype, b: @TypeOf(a)) std.math.Order {
    return Cmp(@TypeOf(a)).cmp(a, b);
}

pub fn lt(a: anytype, b: @TypeOf(a)) bool {
    return Cmp(@TypeOf(a)).lt(a, b);
}

pub fn eq(a: anytype, b: @TypeOf(a)) bool {
    return Cmp(@TypeOf(a)).eq(a, b);
}

pub fn gt(a: anytype, b: @TypeOf(a)) bool {
    return Cmp(@TypeOf(a)).gt(a, b);
}

test {
    try std.testing.expect(lt(1, 2));
    try std.testing.expect(eq(2, 2));
    try std.testing.expect(gt(2, 1));
}
