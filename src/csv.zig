const std = @import("std");
const meta = @import("meta.zig");
const Context = @import("context.zig").Context;

const WriterOptions = struct {
    header: bool = true,
    delimiter: u8 = ',',
};

pub const Writer = struct {
    inner: *std.Io.Writer,
    options: WriterOptions,
    row: usize = 0,
    col: usize = 0,

    pub fn init(inner: *std.Io.Writer, options: WriterOptions) Writer {
        return .{ .inner = inner, .options = options };
    }

    pub fn write(self: *Writer, value: anytype) !void {
        const T = @TypeOf(value);

        if (self.col > 0) {
            try self.inner.writeByte(self.options.delimiter);
        }

        switch (@typeInfo(T)) {
            .void, .null => {},
            .bool => try self.inner.writeAll(if (value) "true" else "false"),
            .int, .comptime_int => try self.inner.print("{}", .{value}),
            .float, .comptime_float => try self.inner.print("{d}", .{value}),
            .@"struct" => try self.writeRow(value),
            .array => |a| try self.write(@as([]const a.child, &value)),
            .pointer => |p| {
                if (meta.isString(T)) {
                    if (std.mem.indexOfAny(u8, value, ",;\t|\r\n\"")) |_| {
                        try self.writeQuoted(value);
                    } else {
                        try self.inner.writeAll(value);
                    }
                } else if (meta.isSlice(T)) {
                    if (meta.isStruct(p.child) and self.options.header) {
                        try self.writeHeader(std.meta.fieldNames(p.child));
                    }

                    for (value) |row| try self.writeRow(row);
                } else {
                    try self.write(value.*);
                }
            },
            else => @compileError("TODO: " ++ @typeName(T)),
        }

        self.col += 1;
    }

    pub fn writeHeader(self: *Writer, field_names: []const []const u8) !void {
        for (field_names) |f| try self.write(f);
        self.row += 1;
        self.col = 0;
    }

    pub fn writeRow(self: *Writer, row: anytype) !void {
        if (self.row > 0) {
            try self.inner.writeByte('\n');
        }

        inline for (comptime std.meta.fieldNames(@TypeOf(row))) |f| {
            try self.write(@field(row, f));
        }

        self.row += 1;
        self.col = 0;
    }

    pub fn writeQuoted(self: *Writer, chunk: []const u8) !void {
        try self.inner.writeByte('"');

        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, chunk, pos, '"')) |i| {
            try self.inner.writeAll(chunk[pos..i]);
            try self.inner.writeAll("\"\"");
            pos = i + 1;
        }

        if (pos < chunk.len) {
            try self.inner.writeAll(chunk[pos..]);
        }

        try self.inner.writeByte('"');
    }
};

const Person = struct {
    name: []const u8,
    age: u32,
};

const people: []const Person = &.{
    .{ .name = "John", .age = 30 },
    .{ .name = "Jane", .age = 25 },
};

fn expectCsv(options: WriterOptions, val: anytype, expected: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var cw = Writer.init(&aw.writer, options);
    try cw.write(val);

    return std.testing.expectEqualStrings(expected, aw.written());
}

test "basic usage" {
    try expectCsv(.{}, people[0..1], "name,age\nJohn,30");
    try expectCsv(.{}, people, "name,age\nJohn,30\nJane,25");
}

test "tuples" {
    try expectCsv(.{}, .{}, "");
    try expectCsv(.{}, .{"foo"}, "foo");
    try expectCsv(.{}, .{ "foo", 123 }, "foo,123");
}

test "delimiter" {
    try expectCsv(.{ .delimiter = ';' }, people, "name;age\nJohn;30\nJane;25");
}

test "quoting" {
    try expectCsv(.{}, "foo,bar", "\"foo,bar\"");
    try expectCsv(.{}, "foo\nbar", "\"foo\nbar\"");
    try expectCsv(.{}, "foo \"bar\"", "\"foo \"\"bar\"\"\"");
}
