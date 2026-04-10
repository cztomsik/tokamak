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
        }
    }

    pub fn beginSeq(self: *Writer, _: usize) !Seq {
        try self.inner.beginArray();
        return .{ .writer = self };
    }

    pub fn beginTuple(self: *Writer, _: usize) !Tuple {
        try self.inner.beginArray();
        return .{ .writer = self };
    }

    pub fn beginStruct(self: *Writer, comptime _: type, _: usize) !Struct {
        try self.inner.beginObject();
        return .{ .writer = self };
    }

    pub fn beginMap(self: *Writer, _: usize) !Map {
        try self.inner.beginObject();
        return .{ .writer = self };
    }
};

const Seq = struct {
    writer: *Writer,

    pub fn element(self: *Seq, value: anytype) !void {
        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Seq) !void {
        try self.writer.inner.endArray();
    }
};

const Tuple = struct {
    writer: *Writer,

    pub fn element(self: *Tuple, value: anytype) !void {
        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Tuple) !void {
        try self.writer.inner.endArray();
    }
};

const Struct = struct {
    writer: *Writer,

    pub fn field(self: *Struct, key: []const u8, value: anytype) !void {
        try self.writer.inner.objectField(key);
        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Struct) !void {
        try self.writer.inner.endObject();
    }
};

const Map = struct {
    writer: *Writer,

    pub fn entry(self: *Map, key: anytype, value: anytype) !void {
        try self.writer.inner.objectField(@as([]const u8, key));
        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Map) !void {
        try self.writer.inner.endObject();
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

test "structs" {
    try expectJson(.{ .name = "John", .age = 123 }, "{\n  \"name\": \"John\",\n  \"age\": 123\n}");
    try expectJson(users[0], "{\n  \"name\": \"John Doe\",\n  \"age\": 21\n}");
    try expectJson(.{ .user = users[0] }, "{\n  \"user\": {\n    \"name\": \"John Doe\",\n    \"age\": 21\n  }\n}");
}

test "slices" {
    try expectJson(users, "[\n  {\n    \"name\": \"John Doe\",\n    \"age\": 21\n  },\n  {\n    \"name\": \"Jane Doe\",\n    \"age\": 23\n  }\n]");
    try expectJson(stories[0], "{\n  \"id\": 123,\n  \"title\": \"Root\",\n  \"kids\": [\n    456,\n    789\n  ]\n}");
    try expectJson(stories[1], "{\n  \"id\": 456,\n  \"title\": \"Leaf\",\n  \"kids\": []\n}");
    try expectJson([_][]const u32{ &.{ 1, 2 }, &.{ 3, 4 } }, "[\n  [\n    1,\n    2\n  ],\n  [\n    3,\n    4\n  ]\n]");
}

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
