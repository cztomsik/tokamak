// https://ruudvanasseldonk.com/2023/01/11/the-yaml-document-from-hell
// https://yaml.org/spec/1.2.2/

const std = @import("std");
const meta = @import("meta.zig");

// TODO: this is still WIP, do not use it for anything important
pub const Writer = struct {
    writer: std.io.AnyWriter,
    indent: usize = 0,

    pub fn init(writer: std.io.AnyWriter) Writer {
        return .{ .writer = writer };
    }

    pub fn writeValue(self: *Writer, value: anytype) !void {
        const T = @TypeOf(value);

        if (comptime meta.isString(T)) {
            return self.writeString(value);
        }

        if (comptime meta.isSlice(T)) {
            return self.writeSlice(value);
        }

        try switch (@typeInfo(T)) {
            .void, .null => self.writer.writeAll("null"),
            .bool => self.writer.print("{}", .{value}),
            .int, .comptime_int => self.writer.print("{}", .{value}),
            .float, .comptime_float => self.writer.print("!!float {d}", .{value}),
            .@"enum", .enum_literal => self.writeString(@tagName(value)),
            .error_set => self.writeString(@errorName(value)),
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
        // TODO: Let's keep it simple for now
        const needs_escape = value.len == 0 or
            std.mem.eql(u8, value, "true") or
            std.mem.eql(u8, value, "false") or
            for (value) |ch| {
                if (!std.ascii.isAlphabetic(ch)) break true;
            } else false;

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
                try self.writer.writeAll("\n\n");
            }

            try self.writeIndent();
            try self.writer.writeAll("- ");

            const n = self.maybePush(@TypeOf(it));
            defer self.indent -= n;

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
                try self.writeIndent();
            }

            try self.writeKey(f.name);
            try self.writer.writeAll(": ");

            const n = self.maybePush(f.type);
            defer self.indent -= n;

            try self.writeValue(@field(value, f.name));
        }
    }

    fn writeKey(self: *Writer, key: []const u8) !void {
        // TODO: I think we might need two separate needs_escape impls.
        return self.writeString(key);
    }

    fn writeIndent(self: *Writer) !void {
        try self.writer.writeBytesNTimes("  ", self.indent);
    }

    fn maybePush(self: *Writer, comptime T: type) usize {
        if (meta.isSlice(T) or meta.isStruct(T)) {
            self.indent += 1;
            return 1;
        } else return 0;
    }
};

const testing = @import("testing.zig");

const User = struct { name: []const u8, age: u32 };

const users: []const User = &.{
    .{ .name = "John", .age = 21 },
    .{ .name = "Jane", .age = 23 },
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
        \\name: John
        \\age: 21
    );

    try expectYaml(users,
        \\- name: John
        \\  age: 21
        \\
        \\- name: Jane
        \\  age: 23
    );

    // edge-cases
    try expectYaml("", "\"\"");
    try expectYaml("true", "\"true\"");
    try expectYaml("foo:bar", "\"foo:bar\"");
    try expectYaml(.{}, "{}");
    try expectYaml(users[0..0], "[]");
}
