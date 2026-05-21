const std = @import("std");
const serde = @import("../serde.zig");
const testing = @import("../testing.zig");

const Delimiter = enum {
    comma, // US
    semicolon, // EU
    tab,
    pipe,
};

const WriterOptions = struct {
    header: bool = true,
    delimiter: Delimiter = .comma,
};

pub const Writer = struct {
    inner: *std.io.Writer,
    options: WriterOptions,
    row: usize = 0,
    col: usize = 0,

    pub fn init(inner: *std.io.Writer, options: WriterOptions) Writer {
        return .{ .inner = inner, .options = options };
    }

    pub fn write(self: *Writer, comptime k: serde.Kind, value: anytype) !void {
        if (self.col > 0) {
            try self.inner.writeByte(switch (self.options.delimiter) {
                .comma => ',',
                .semicolon => ';',
                .tab => '\t',
                .pipe => '|',
            });
        }

        switch (k) {
            .void, .null => {},
            .bool => try self.inner.writeAll(if (value) "true" else "false"),
            .int => try self.inner.print("{}", .{value}),
            .float => try self.inner.print("{d}", .{value}),
            .string => if (std.mem.indexOfAny(u8, value, ",;\t|\r\n\"")) |_| {
                try self.writeQuoted(value);
            } else {
                try self.inner.writeAll(value);
            },
        }

        self.col += 1;
    }

    pub fn beginSeq(self: *Writer, _: usize) !Seq {
        return .{ .writer = self };
    }

    pub fn beginTuple(self: *Writer, _: usize) !Tuple {
        if (self.row > 0) {
            try self.inner.writeByte('\n');
        }

        return .{ .writer = self };
    }

    pub fn beginStruct(self: *Writer, comptime T: type, _: usize) !Struct {
        if (self.row == 0 and self.options.header) {
            try self.writeHeader(std.meta.fields(T));
        }

        if (self.row > 0) {
            try self.inner.writeByte('\n');
        }

        return .{ .writer = self };
    }

    fn writeHeader(self: *Writer, comptime fields: anytype) !void {
        inline for (fields) |f| {
            try self.write(.string, f.name);
            self.col += 1;
        }
        self.row += 1;
        self.col = 0;
    }

    fn writeQuoted(self: *Writer, chunk: []const u8) !void {
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

const Seq = struct {
    writer: *Writer,

    pub fn element(self: *Seq, value: anytype) !void {
        try serde.serialize(self.writer, value);
    }

    pub fn end(_: *Seq) !void {}
};

const Tuple = struct {
    writer: *Writer,

    pub fn element(self: *Tuple, value: anytype) !void {
        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Tuple) !void {
        if (self.writer.col > 0) {
            self.writer.row += 1;
            self.writer.col = 0;
        }
    }
};

const Struct = struct {
    writer: *Writer,

    pub fn field(self: *Struct, _: []const u8, value: anytype) !void {
        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Struct) !void {
        if (self.writer.col > 0) {
            self.writer.row += 1;
            self.writer.col = 0;
        }
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
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    var w = Writer.init(&wb.writer, options);
    try serde.serialize(&w, val);

    return testing.expectEqual(wb.written(), expected);
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
    try expectCsv(.{ .delimiter = .semicolon }, people, "name;age\nJohn;30\nJane;25");
}

test "quoting" {
    try expectCsv(.{}, "foo,bar", "\"foo,bar\"");
    try expectCsv(.{}, "foo\nbar", "\"foo\nbar\"");
    try expectCsv(.{}, "foo \"bar\"", "\"foo \"\"bar\"\"\"");
}
