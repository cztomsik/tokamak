const std = @import("std");
const meta = @import("../meta.zig");

pub fn stringify(value: anytype, writer: anytype) !void {
    try writeValue(value, writer);
}

pub fn stringifyAlloc(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var bw = std.io.Writer.Allocating.init(arena);
    try writeValue(value, &bw.writer);
    return bw.toOwnedSlice();
}

pub fn fmt(value: anytype) Formatter(@TypeOf(value)) {
    return .{ .value = value };
}

pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,

        pub fn format(self: @This(), writer: anytype) !void {
            try writeValue(self.value, writer);
        }
    };
}

// TODO: we should probably pub more methods so that they can be used in the custom T.formatAi() hook
fn writeValue(value: anytype, writer: anytype) !void {
    // TODO: custom T.formatAi() hook
    const T = @TypeOf(value);

    if (meta.isSlice(T) and meta.isStruct(std.meta.Elem(T))) {
        return writeTable(std.meta.Elem(T), value, writer);
    }

    if (meta.isString(T)) {
        return writer.writeAll(value);
    }

    if (std.meta.hasMethod(T, "format")) {
        return value.format("", .{}, writer);
    }

    return switch (@typeInfo(T)) {
        .void => writer.print("success", .{}), // TODO: is this enough encouraging?
        .error_set => writer.print("error: {s}", .{@errorName(value)}),
        .error_union => if (value) |r| writeValue(r, writer) else |e| writeValue(e, writer),
        else => std.json.fmt(value, .{ .whitespace = .indent_2 }).format(writer),
    };
}

// TODO: writeTableMasked(T, items, field_mask: usize)
fn writeTable(comptime T: type, items: []const T, writer: anytype) !void {
    const fields = std.meta.fields(T);

    var widths: [fields.len]usize = undefined;
    inline for (fields, 0..) |f, i| widths[i] = f.name.len;

    // Grow widths to fit values
    for (items) |item| {
        inline for (fields, 0..) |f, i| {
            widths[i] = @max(widths[i], getValueLength(@field(item, f.name)));
        }
    }

    // Write header
    try writer.writeAll("|");
    inline for (fields, 0..) |field, i| {
        try writer.writeByte(' ');
        try writer.writeAll(field.name);
        try writer.writeByteNTimes(' ', widths[i] - field.name.len);
        try writer.writeAll(" |");
    }
    try writer.writeAll("\n");

    // Write |---|-|--| separator
    try writer.writeAll("|");
    inline for (widths) |width| {
        try writer.writeAll("-");
        try writer.writeByteNTimes('-', width);
        try writer.writeAll("-|");
    }
    try writer.writeAll("\n");

    // Write items
    for (items) |item| {
        try writer.writeAll("|");
        inline for (fields, 0..) |field, i| {
            try writer.writeAll(" ");
            const v = @field(item, field.name);
            try writeValue(v, writer);
            try writer.writeByteNTimes(' ', widths[i] - getValueLength(v));
            try writer.writeAll(" |");
        }
        try writer.writeAll("\n");
    }
}

fn getValueLength(value: anytype) usize {
    return std.fmt.count("{f}", .{fmt(value)});
}

const Person = struct { name: []const u8, age: u32 };
const people: []const Person = &.{
    .{
        .name = "John Doe",
        .age = 30,
    },
    .{
        .name = "Jessica Doe",
        .age = 29,
    },
    .{
        .name = "X",
        .age = 0,
    },
};

test {
    try testing.expectFmt(fmt({}), "success");
    try testing.expectFmt(fmt(error.NotFound), "error: NotFound");
    try testing.expectFmt(fmt(123), "123");
    try testing.expectFmt(fmt("Hello"), "Hello");

    try testing.expectFmt(fmt(.{ .name = "John Doe", .age = 30 }),
        \\{
        \\  "name": "John Doe",
        \\  "age": 30
        \\}
    );

    try testing.expectFmt(fmt(people),
        \\| name        | age |
        \\|-------------|-----|
        \\| John Doe    | 30  |
        \\| Jessica Doe | 29  |
        \\| X           | 0   |
        \\
    );

    try testing.expectFmt(fmt(@as([]const Person, people[2..])),
        \\| name | age |
        \\|------|-----|
        \\| X    | 0   |
        \\
    );
}
