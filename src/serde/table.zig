const std = @import("std");
const serde = @import("../serde.zig");
const testing = @import("../testing.zig");

pub const Col = struct {
    name: []const u8,
    width: u32,
};

const WriterOptions = struct {
    // TODO: maybe we should split columns and widths to separate options?
    columns: []const Col,
};

pub const Writer = struct {
    buf: []u8,
    inner: *std.io.Writer,
    options: WriterOptions,
    row: usize = 0,
    col: usize = 0,

    pub fn init(buf: []u8, writer: *std.io.Writer, options: WriterOptions) Writer {
        return .{ .buf = buf, .inner = writer, .options = options };
    }

    pub fn write(self: *Writer, comptime k: serde.Kind, value: anytype) !void {
        switch (k) {
            .void, .null => try self.writeCell(""),
            .bool => try self.writeCell(if (value) "true" else "false"),
            .int => try self.writeCell(try std.fmt.bufPrint(self.buf, "{}", .{value})),
            .float => try self.writeCell(try std.fmt.bufPrint(self.buf, "{d}", .{value})),
            .string => try self.writeCell(value),
        }
    }

    pub fn beginSeq(self: *Writer, _: usize) !Seq {
        try self.ensureHeader();
        return .{ .writer = self };
    }

    pub fn beginTuple(self: *Writer, _: usize) !Tuple {
        try self.ensureHeader();
        return .{ .writer = self };
    }

    pub fn beginStruct(self: *Writer, comptime _: type, _: usize) !Struct {
        try self.ensureHeader();
        return .{ .writer = self };
    }

    fn writeHeader(self: *Writer) !void {
        try self.beginRow();

        for (self.options.columns) |col| {
            try self.writeCell(col.name);
        }

        try self.endRow();
    }

    fn writeSeparator(self: *Writer) !void {
        try self.inner.writeAll("\n|");

        for (self.options.columns) |col| {
            try self.inner.splatByteAll('-', col.width + 2);
            try self.inner.writeByte('|');
        }
    }

    fn beginRow(self: *Writer) !void {
        if (self.row > 0) try self.inner.writeByte('\n');
        try self.inner.writeAll("| ");
    }

    fn endRow(self: *Writer) !void {
        try self.inner.writeAll(" |");
        self.col = 0;
        self.row += 1;
    }

    fn writeCell(self: *Writer, value: []const u8) !void {
        const width = self.options.columns[self.col].width;
        if (self.col > 0) try self.inner.writeAll(" | ");
        defer self.col += 1;

        if (value.len > width) {
            try self.inner.writeAll(value[0 .. width - 1]);
            try self.inner.writeByte('.');
        } else {
            try self.inner.writeAll(value);
            if (value.len < width) {
                try self.inner.splatByteAll(' ', width - value.len);
            }
        }
    }

    fn ensureHeader(self: *Writer) !void {
        if (self.row == 0) {
            try self.writeHeader();
            try self.writeSeparator();
        }
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
    started: bool = false,

    pub fn element(self: *Tuple, value: anytype) !void {
        if (!self.started) {
            try self.writer.beginRow();
            self.started = true;
        }

        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Tuple) !void {
        if (self.started) try self.writer.endRow();
    }
};

const Struct = struct {
    writer: *Writer,
    started: bool = false,

    pub fn field(self: *Struct, key: []const u8, value: anytype) !void {
        if (!self.started) {
            try self.writer.beginRow();
            self.started = true;
        }

        if (self.writer.col >= self.writer.options.columns.len) return;
        if (!std.mem.eql(u8, self.writer.options.columns[self.writer.col].name, key)) return;
        try serde.serialize(self.writer, value);
    }

    pub fn end(self: *Struct) !void {
        if (self.started) try self.writer.endRow();
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

const people_cols: []const Col = &.{
    .{ .name = "name", .width = 8 },
    .{ .name = "age", .width = 3 },
};

fn expectTable(val: anytype, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    var w = Writer.init(&buf, &wb.writer, .{ .columns = people_cols });
    try serde.serialize(&w, val);

    return testing.expectEqual(wb.written(), expected);
}

test "basic" {
    try expectTable(people[0..1],
        \\| name     | age |
        \\|----------|-----|
        \\| John     | 30  |
    );
    try expectTable(people,
        \\| name     | age |
        \\|----------|-----|
        \\| John     | 30  |
        \\| Jane     | 25  |
    );
}

test "empty" {
    try expectTable(people[0..0],
        \\| name     | age |
        \\|----------|-----|
    );
}

test "truncation" {
    const long: []const Person = &.{.{ .name = "Alexander", .age = 1000 }};
    try expectTable(long,
        \\| name     | age |
        \\|----------|-----|
        \\| Alexand. | 10. |
    );
}
