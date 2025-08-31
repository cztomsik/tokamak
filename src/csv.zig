const std = @import("std");
const meta = @import("meta.zig");
const Context = @import("context.zig").Context;

pub fn Response(comptime T: type) type {
    return struct {
        items: []const T,
        options: WriterOptions = .{},

        pub fn sendResponse(self: *@This(), ctx: *Context) !void {
            const w = Writer.init(ctx.res.writer(), self.options);
            ctx.responded = true;

            try w.writeAll(T, self.items);
        }
    };
}

const Delimiter = enum {
    comma, // US
    semicolon, // EU
    tab,
    pipe,
};

const WriterOptions = struct {
    delimiter: Delimiter = .comma,
    // TODO: cr lf?
    // TODO: trailing cr lf?
    // TODO: bool mapping [2][]const u8?
};

pub const Writer = struct {
    inner: *std.io.Writer,
    options: WriterOptions,
    row: usize = 0,
    col: usize = 0,

    pub fn init(inner: *std.io.Writer, options: WriterOptions) Writer {
        return .{
            .inner = inner,
            .options = options,
        };
    }

    pub fn writeAll(self: *Writer, comptime T: type, items: []const T) !void {
        try self.writeHeader(T);

        for (items) |it| {
            try self.writeRow(it);
        }
    }

    pub fn writeHeader(self: *Writer, comptime T: type) !void {
        inline for (std.meta.fields(T)) |f| {
            try self.writeValue(f.name);
        }

        self.row += 1;
        self.col = 0;
    }

    pub fn writeRow(self: *Writer, row: anytype) !void {
        const T = @TypeOf(row);

        if (self.row > 0) {
            try self.inner.writeByte('\n');
        }

        switch (@typeInfo(T)) {
            .@"struct" => {
                inline for (std.meta.fields(T)) |f| {
                    try self.writeValue(@field(row, f.name));
                }
            },
            else => |ti| @compileError("TODO " ++ @tagName(ti)),
        }

        self.row += 1;
        self.col = 0;
    }

    pub fn finish(self: *Writer) !void {
        // TODO: if (self.options.trailing_crlf) write trailing CR LF
        _ = self;
    }

    fn writeValue(self: *Writer, value: anytype) !void {
        const T = @TypeOf(value);

        if (self.col > 0) {
            try self.inner.writeByte(switch (self.options.delimiter) {
                .comma => ',',
                .semicolon => ';',
                .tab => '\t',
                .pipe => '|',
            });
        }

        switch (@typeInfo(T)) {
            .int, .comptime_int, .float, .comptime_float => try self.inner.print("{}", .{value}),
            else => {
                if (meta.isString(@TypeOf(value))) {
                    if (std.mem.indexOfAny(u8, value, ",;\t|\r\n\"")) |_| {
                        try self.writeQuoted(value);
                    } else {
                        try self.inner.writeAll(value);
                    }
                } else {
                    @compileError("TODO " ++ @typeName(T));
                }
            },
        }

        self.col += 1;
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

const t = std.testing;

const Person = struct {
    name: []const u8,
    age: u32,
};

test "basic usage" {
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    var w = Writer.init(&wb.writer, .{});

    try w.writeHeader(Person);
    try t.expectEqualStrings(
        "name,age",
        wb.written(),
    );

    try w.writeRow(Person{ .name = "John", .age = 30 });
    try t.expectEqualStrings(
        "name,age\n" ++
            "John,30",
        wb.written(),
    );
}

test "tuples" {
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    var w = Writer.init(&wb.writer, .{});

    try w.writeRow(.{ "foo", 123 });
    try w.writeRow(.{ "bar", 456 });

    try t.expectEqualStrings(
        "foo,123\n" ++
            "bar,456",
        wb.written(),
    );
}

test "delimiter" {
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    var w = Writer.init(&wb.writer, .{ .delimiter = .semicolon });

    try w.writeHeader(Person);
    try t.expectEqualStrings(
        "name;age",
        wb.written(),
    );
}

test "quoting" {
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    var w = Writer.init(&wb.writer, .{});

    try w.writeRow(.{ "foo,bar", 123 });
    try w.writeRow(.{ 456, "foo\nbar" });
    try w.writeRow(.{ 789, "foo \"bar\"" });
    try t.expectEqualStrings(
        "\"foo,bar\",123\n" ++
            "456,\"foo\nbar\"\n" ++
            "789,\"foo \"\"bar\"\"\"",
        wb.written(),
    );
}
