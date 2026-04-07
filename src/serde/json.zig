const std = @import("std");
const meta = @import("../meta.zig");
const serde = @import("../serde.zig");
const testing = @import("../testing.zig");

pub const Writer = struct {
    inner: std.json.Stringify,

    pub fn init(iow: *std.io.Writer, options: std.json.Stringify.Options) Writer {
        return .{ .inner = .{ .writer = iow, .options = options } };
    }

    pub fn write(self: *Writer, comptime k: serde.Kind, value: anytype) !void {
        switch (k) {
            .void => try self.inner.write(null),
            .null, .bool, .int, .float, .string => try self.inner.write(value),
            .array_begin, .tuple_begin => try self.inner.beginArray(),
            .array_end, .tuple_end => try self.inner.endArray(),
            .struct_begin => try self.inner.beginObject(),
            .struct_field => try self.inner.objectField(value),
            .struct_end => try self.inner.endObject(),
        }
    }
};

const User = struct { name: []const u8, age: u32 };
const Address = struct { street: []const u8, city: []const u8, zip: u32 };
const Story = struct { id: u64, title: []const u8, kids: ?[]const u64 };

const users: []const User = &.{
    .{ .name = "John Doe", .age = 21 },
    .{ .name = "Jane Doe", .age = 23 },
};

const stories: []const Story = &.{
    .{ .id = 123, .title = "Root", .kids = &[_]u64{ 456, 789 } },
    .{ .id = 456, .title = "Leaf", .kids = &[_]u64{} },
};

pub fn expectJson(val: anytype, expected: []const u8) !void {
    var bw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer bw.deinit();

    var w = Writer.init(&bw.writer, .{ .whitespace = .indent_2 });
    try serde.serialize(&w, val);

    return testing.expectEqual(bw.written(), expected);
}

test "scalars" {
    try expectJson({}, "null");
    try expectJson(null, "null");
    try expectJson(true, "true");
    try expectJson(123, "123");
    try expectJson(12.3, "12.3");
    try expectJson("bar", "\"bar\"");
    try expectJson(.foo, "\"foo\"");
}

// TODO: fix expected (whitespace)
// test "structs" {
//     try expectJson(.{ .name = "John", .age = 123 }, "{\"name\":\"John\",\"age\":123}");
//     try expectJson(users[0], "{\"name\":\"John Doe\",\"age\":21}");
//     try expectJson(.{ .user = users[0] }, "{\"user\":{\"name\":\"John Doe\",\"age\":21}}");
// }

// TODO: fix expected (whitespace)
// test "slices" {
//     try expectJson(users, "[{\"name\":\"John Doe\",\"age\":21},{\"name\":\"Jane Doe\",\"age\":23}]");
//     try expectJson(stories[0], "{\"id\":123,\"title\":\"Root\",\"kids\":[456,789]}");
//     try expectJson(stories[1], "{\"id\":456,\"title\":\"Leaf\",\"kids\":[]}");
//     try expectJson([_][]const u32{ &.{ 1, 2 }, &.{ 3, 4 } }, "[[1,2],[3,4]]");
// }

test "tuples" {
    try expectJson(.{}, "[]");
    try expectJson(.{1}, "[\n  1\n]");
    try expectJson(.{ 1, "foo", true }, "[\n  1,\n  \"foo\",\n  true\n]");
}

test "empty" {
    const Empty = struct {};
    try expectJson(Empty{}, "{}");
    try expectJson(users[0..0], "[]");
}
