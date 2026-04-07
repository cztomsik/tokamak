// https://ruudvanasseldonk.com/2023/01/11/the-yaml-document-from-hell
// https://yaml.org/spec/1.2.2/

const std = @import("std");
const meta = @import("../meta.zig");
const serde = @import("../serde.zig");
const testing = @import("../testing.zig");

pub const WriterOptions = struct {};

// TODO: this is still WIP, do not use it for anything important
pub const Writer = struct {
    writer: *std.io.Writer,
    options: WriterOptions,
    indent: usize = 0,
    after_dash: bool = false,
    skip_depth: usize = 0,

    pub fn init(writer: *std.io.Writer, options: WriterOptions) Writer {
        return .{ .writer = writer, .options = options };
    }

    pub fn write(self: *Writer, comptime k: serde.Kind, value: anytype) !void {
        if (self.skip_depth > 0) {
            switch (k) {
                .array_begin, .tuple_begin, .struct_begin => self.skip_depth += 1,
                .array_end, .tuple_end, .struct_end => self.skip_depth -= 1,
                else => {},
            }
            return;
        }

        switch (k) {
            .void, .null => try self.writer.writeAll("null"),
            .bool, .int => try self.writer.print("{}", .{value}),
            .float => try self.writer.print("!!float {d}", .{value}),
            .string => try self.writeString(value),
            .array_begin => {
                try self.writeSlice(value);
                self.skip_depth = 1;
            },
            .tuple_begin => {
                try self.writeTuple(value);
                self.skip_depth = 1;
            },
            .struct_begin => {
                try self.writeStruct(value);
                self.skip_depth = 1;
            },
            .struct_field, .array_end, .tuple_end, .struct_end => {},
        }
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

    fn writeSlice(self: *Writer, items: anytype) !void {
        if (items.len == 0) {
            return self.writer.writeAll("[]");
        }

        for (items, 0..) |it, i| {
            if (i > 0) {
                try self.writer.writeAll(if (shouldInline(it)) "\n" else "\n\n");
            }

            if (!self.after_dash or i > 0) {
                try self.writeIndent();
            }

            try self.writer.writeAll("- ");
            self.after_dash = true;

            self.indent += 1;
            defer self.indent -= 1;
            try serde.serialize(self, it);
        }
    }

    fn writeTuple(self: *Writer, value: anytype) !void {
        const fields = std.meta.fields(@TypeOf(value));

        if (fields.len == 0) {
            return self.writer.writeAll("[]");
        }

        inline for (fields, 0..) |_, i| {
            const it = value[i];

            if (i > 0) {
                try self.writer.writeAll(if (shouldInline(it)) "\n" else "\n\n");
            }

            if (!self.after_dash or i > 0) {
                try self.writeIndent();
            }

            try self.writer.writeAll("- ");
            self.after_dash = true;

            self.indent += 1;
            try serde.serialize(self, it);
            self.indent -= 1;
        }
    }

    fn writeStruct(self: *Writer, value: anytype) !void {
        const fields = std.meta.fields(@TypeOf(value));

        if (fields.len == 0) {
            return self.writer.writeAll("{}");
        }

        inline for (fields, 0..) |f, i| {
            if (i > 0) {
                try self.writer.writeByte('\n');
            }

            if (!self.after_dash) {
                try self.writeIndent();
            } else {
                self.after_dash = false;
            }

            try serde.serialize(self, f.name);
            try self.writer.writeAll(": ");

            const val = @field(value, f.name);

            if (shouldInline(val)) {
                try serde.serialize(self, val);
            } else {
                try self.writer.writeByte('\n');
                self.indent += 1;
                try serde.serialize(self, val);
                self.indent -= 1;
            }
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
            .@"struct" => |s| s.fields.len == 0,
            .array => shouldInline(&value[0..]),
            .optional => if (value) |v| shouldInline(v) else true,
            .pointer => shouldInline(value.*),
            else => true,
        };
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

fn expectYaml(val: anytype, expected: []const u8) !void {
    var bw = std.io.Writer.Allocating.init(std.testing.allocator);
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
