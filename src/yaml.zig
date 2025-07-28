// https://ruudvanasseldonk.com/2023/01/11/the-yaml-document-from-hell
// https://yaml.org/spec/1.2.2/

const std = @import("std");
const meta = @import("meta.zig");

// TODO: this is still WIP, do not use it for anything important
pub const Writer = struct {
    writer: std.io.AnyWriter,
    indent: usize = 0,
    after_dash: bool = false,

    pub fn init(writer: std.io.AnyWriter) Writer {
        return .{ .writer = writer };
    }

    pub fn writeValue(self: *Writer, value: anytype) !void {
        const T = @TypeOf(value);

        if (meta.isString(T)) {
            return self.writeString(value);
        }

        if (meta.isSlice(T)) {
            return self.writeSlice(value);
        }

        try switch (@typeInfo(T)) {
            .void, .null => self.writer.writeAll("null"),
            .bool => self.writer.print("{}", .{value}),
            .int, .comptime_int => self.writer.print("{}", .{value}),
            .float, .comptime_float => self.writer.print("!!float {d}", .{value}),
            .@"enum", .enum_literal => self.writeString(@tagName(value)),
            .error_set => self.writeString(@errorName(value)),
            .array => self.writeSlice(&value),
            .pointer => |p| {
                if (@typeInfo(p.child) == .array) {
                    return self.writeSlice(value[0..]);
                } else {
                    return self.writeValue(value.*);
                }
            },
            .optional => if (value) |v| self.writeValue(v) else self.writeValue(null),
            .@"struct" => self.writeStruct(value),

            // TODO
            else => self.writer.print("<{s}>", .{@typeName(T)}),
        };
    }

    pub fn writeString(self: *Writer, value: []const u8) !void {
        // TODO: Is this enough? Is it also enough for keys?
        const needs_escape = value.len == 0 or
            std.mem.eql(u8, value, "true") or
            std.mem.eql(u8, value, "false") or
            std.mem.eql(u8, value, "null") or
            std.mem.indexOfAny(u8, value, ":#@*&{}[]|>'\"\n\r") != null or
            (value[0] == ' ' or value[value.len - 1] == ' ');

        if (needs_escape) {
            try self.writer.print("{}", .{std.json.fmt(value, .{})});
        } else {
            try self.writer.writeAll(value);
        }
    }

    pub fn writeSlice(self: *Writer, items: anytype) !void {
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
            try self.writeValue(it);
        }
    }

    pub fn writeStruct(self: *Writer, value: anytype) !void {
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

            try self.writeValue(f.name);
            try self.writer.writeAll(": ");

            const val = @field(value, f.name);

            if (shouldInline(val)) {
                try self.writeValue(val);
            } else {
                try self.writer.writeByte('\n');
                self.indent += 1;
                try self.writeValue(val);
                self.indent -= 1;
            }
        }
    }

    fn writeIndent(self: *Writer) !void {
        try self.writer.writeBytesNTimes("  ", self.indent);
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

const testing = @import("testing.zig");

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
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var w = Writer.init(buf.writer().any());
    try w.writeValue(val);

    return testing.expectEqual(buf.items, expected);
}

test {
    try expectYaml({}, "null");
    try expectYaml(null, "null");
    try expectYaml(true, "true");
    try expectYaml(123, "123");
    try expectYaml(12.3, "!!float 12.3");
    try expectYaml("bar", "bar");
    try expectYaml(.foo, "foo");

    // comptime anytype
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

    // edge-cases
    try expectYaml("", "\"\"");
    try expectYaml("true", "\"true\"");
    try expectYaml("foo:bar", "\"foo:bar\"");
    try expectYaml(.{}, "{}");
    try expectYaml(users[0..0], "[]");
    try expectYaml([_][]const u32{ &.{ 1, 2 }, &.{ 3, 4 } },
        \\- - 1
        \\  - 2
        \\
        \\- - 3
        \\  - 4
    );
}
