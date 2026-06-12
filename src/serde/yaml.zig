// https://ruudvanasseldonk.com/2023/01/11/the-yaml-document-from-hell
// https://yaml.org/spec/1.2.2/

const std = @import("std");
const meta = @import("../meta.zig");
const serde = @import("../serde.zig");
const testing = @import("../testing.zig");

pub const WriterOptions = struct {};

// TODO: this is still WIP, do not use it for anything important
pub const Writer = struct {
    writer: *std.Io.Writer,
    options: WriterOptions,
    indent: usize = 0,
    after_dash: bool = false,

    pub fn init(writer: *std.Io.Writer, options: WriterOptions) Writer {
        return .{ .writer = writer, .options = options };
    }

    pub fn write(self: *Writer, comptime k: serde.Kind, value: anytype) !void {
        switch (k) {
            .void, .null => try self.writer.writeAll("null"),
            .bool, .int => try self.writer.print("{}", .{value}),
            .float => try self.writer.print("!!float {d}", .{value}),
            .string => try self.writeString(value),
        }
    }

    pub fn beginSeq(self: *Writer, len: usize) !Seq {
        if (len == 0) try self.writer.writeAll("[]");
        return .{ .writer = self };
    }

    pub fn beginTuple(self: *Writer, len: usize) !Tuple {
        if (len == 0) try self.writer.writeAll("[]");
        return .{ .writer = self };
    }

    pub fn beginStruct(self: *Writer, comptime _: type, len: usize) !Struct {
        if (len == 0) try self.writer.writeAll("{}");
        return .{ .writer = self };
    }

    fn writeString(self: *Writer, value: []const u8) !void {
        // TODO: Is this enough? Is it also enough for keys?
        const needs_escape = value.len == 0 or
            std.mem.eql(u8, value, "true") or
            std.mem.eql(u8, value, "false") or
            std.mem.eql(u8, value, "null") or
            std.mem.indexOfAny(u8, value, ":#@*&{}[]|>'\"\n\r") != null or
            (value[0] == ' ' or value[value.len - 1] == ' ');

        if (needs_escape) {
            try self.writer.print("{f}", .{std.json.fmt(value, .{})});
        } else {
            try self.writer.writeAll(value);
        }
    }

    fn writeIndent(self: *Writer) !void {
        try self.writer.splatByteAll(' ', 2 * self.indent);
    }

    fn shouldInline(value: anytype) bool {
        const T = @TypeOf(value);

        if (meta.isString(T)) return true;
        if (meta.isSlice(T)) return value.len == 0;

        return switch (@typeInfo(T)) {
            .@"struct" => |s| s.field_names.len == 0,
            .array => shouldInline(&value[0..]),
            .optional => if (value) |v| shouldInline(v) else true,
            .pointer => shouldInline(value.*),
            else => true,
        };
    }
};

const Seq = struct {
    writer: *Writer,
    index: usize = 0,

    pub fn element(self: *Seq, value: anytype) !void {
        if (self.index > 0) {
            try self.writer.writer.writeAll(if (Writer.shouldInline(value)) "\n" else "\n\n");
        }

        if (!self.writer.after_dash or self.index > 0) {
            try self.writer.writeIndent();
        }

        try self.writer.writer.writeAll("- ");
        self.writer.after_dash = true;

        self.writer.indent += 1;
        defer self.writer.indent -= 1;
        try serde.serialize(self.writer, value);
        self.index += 1;
    }

    pub fn end(_: *Seq) !void {}
};

const Tuple = struct {
    writer: *Writer,
    index: usize = 0,

    pub fn element(self: *Tuple, value: anytype) !void {
        if (self.index > 0) {
            try self.writer.writer.writeAll(if (Writer.shouldInline(value)) "\n" else "\n\n");
        }

        if (!self.writer.after_dash or self.index > 0) {
            try self.writer.writeIndent();
        }

        try self.writer.writer.writeAll("- ");
        self.writer.after_dash = true;

        self.writer.indent += 1;
        defer self.writer.indent -= 1;
        try serde.serialize(self.writer, value);
        self.index += 1;
    }

    pub fn end(_: *Tuple) !void {}
};

const Struct = struct {
    writer: *Writer,
    index: usize = 0,

    pub fn field(self: *Struct, key: []const u8, value: anytype) !void {
        if (self.index > 0) {
            try self.writer.writer.writeByte('\n');
        }

        if (!self.writer.after_dash) {
            try self.writer.writeIndent();
        } else {
            self.writer.after_dash = false;
        }

        try self.writer.write(.string, key);
        try self.writer.writer.writeAll(": ");

        if (Writer.shouldInline(value)) {
            try serde.serialize(self.writer, value);
        } else {
            try self.writer.writer.writeByte('\n');
            self.writer.indent += 1;
            defer self.writer.indent -= 1;
            try serde.serialize(self.writer, value);
        }

        self.index += 1;
    }

    pub fn end(_: *Struct) !void {}
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

fn expectYaml(val: anytype, expected: []const u8) !void {
    var bw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bw.deinit();

    var w = Writer.init(&bw.writer, .{});
    try serde.serialize(&w, val);

    return testing.expectEqual(bw.written(), expected);
}

test "scalars" {
    try expectYaml({}, "null");
    try expectYaml(null, "null");
    try expectYaml(true, "true");
    try expectYaml(123, "123");
    try expectYaml(12.3, "!!float 12.3");
    try expectYaml("bar", "bar");
    try expectYaml(.foo, "foo");
}

test "structs" {
    try expectYaml(.{ .name = "John", .age = 123 },
        \\name: John
        \\age: 123
    );

    try expectYaml(users[0],
        \\name: John Doe
        \\age: 21
    );

    try expectYaml(.{ .user = users[0] },
        \\user: 
        \\  name: John Doe
        \\  age: 21
    );
}

test "slices" {
    try expectYaml(users,
        \\- name: John Doe
        \\  age: 21
        \\
        \\- name: Jane Doe
        \\  age: 23
    );

    try expectYaml(stories[0],
        \\id: 123
        \\title: Root
        \\kids: 
        \\  - 456
        \\  - 789
    );

    try expectYaml(stories[1],
        \\id: 456
        \\title: Leaf
        \\kids: []
    );

    try expectYaml(stories,
        \\- id: 123
        \\  title: Root
        \\  kids: 
        \\    - 456
        \\    - 789
        \\
        \\- id: 456
        \\  title: Leaf
        \\  kids: []
    );

    try expectYaml([_][]const u32{ &.{ 1, 2 }, &.{ 3, 4 } },
        \\- - 1
        \\  - 2
        \\
        \\- - 3
        \\  - 4
    );
}

test "escaping" {
    try expectYaml("", "\"\"");
    try expectYaml("true", "\"true\"");
    try expectYaml("foo:bar", "\"foo:bar\"");
}

test "tuples" {
    try expectYaml(.{}, "[]");
    try expectYaml(.{1}, "- 1");
    try expectYaml(.{ 1, "foo" }, "- 1\n- foo");
}

test "empty" {
    const Empty = struct {};
    try expectYaml(Empty{}, "{}");
    try expectYaml(users[0..0], "[]");
}
