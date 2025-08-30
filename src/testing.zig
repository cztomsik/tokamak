const std = @import("std");
const meta = @import("meta.zig");
const mem = @import("mem.zig");
const http = @import("http.zig");

// re-export
pub const allocator = std.testing.allocator;

pub const time = struct {
    pub var value: i64 = 0;

    pub fn get() i64 {
        return value;
    }

    pub fn getTime() @import("time.zig").Time {
        return @import("time.zig").Time.unix(value);
    }
};

pub const expect = std.testing.expect;

/// Like std.testing.expectError() but with flipped args.
pub fn expectError(res: anytype, expected: anyerror) !void {
    return std.testing.expectError(expected, res);
}

/// Like std.testing.expectEqual() but with flipped args and support for
/// strings and optionals.
pub fn expectEqual(res: anytype, expected: meta.Const(@TypeOf(res))) !void {
    if (meta.isOptional(@TypeOf(res))) {
        if (expected) |e| return expectEqual(res orelse return error.ExpectedValue, e);
        if (res != null) return error.ExpectedNull;
    }

    // TODO: find all usages of expectEqualStrings and replace it with our expectEqual
    if (meta.isString(@TypeOf(res))) {
        return std.testing.expectEqualStrings(expected, res);
    }

    return std.testing.expectEqual(expected, res);
}

/// Attempts to print `arg` into a buf and then compare those strings.
pub fn expectFmt(arg: anytype, expected: []const u8) !void {
    var wb = std.io.Writer.Allocating.init(allocator);
    defer wb.deinit();

    try wb.writer.print("{f}", .{arg});
    try std.testing.expectEqualStrings(expected, wb.written());
}

// TODO: This is similar to the writeTable() fn in ai/fmt.zig but let's take
//       this as an opportunity to get the requirements right first
//       and then maybe it will be easier to come up with good abstraction
pub fn expectTable(items: anytype, comptime expected: []const u8) !void {
    comptime std.debug.assert(meta.isSlice(@TypeOf(items)));

    const header = comptime expected[0..std.mem.indexOfScalar(u8, expected, '\n').?];
    const cols = comptime blk: {
        var cols: [mem.countScalar(u8, header, '|') - 1]Col = undefined;
        var it = std.mem.tokenizeScalar(u8, header, '|');
        for (0..cols.len) |i| {
            const cell = it.next().?;
            cols[i] = .{
                .name = std.mem.trim(u8, cell, " "),
                .width = cell.len - 2,
            };
        }
        break :blk cols;
    };

    var wb = std.io.Writer.Allocating.init(allocator);
    defer wb.deinit();

    var buf: [header.len]u8 = undefined;
    var w = TableWriter.init(&buf, &wb.writer);

    try w.writeHeader(&cols);
    try w.writeSeparator(&cols);

    for (items) |it| {
        try w.writeRow(it, &cols);
    }

    try std.testing.expectEqualStrings(expected, wb.written());
}

const Col = struct {
    name: []const u8,
    width: u32,
};

const TableWriter = struct {
    buf: []u8,
    inner: *std.io.Writer,
    row: usize = 0,
    col: usize = 0,

    pub fn init(buf: []u8, writer: *std.io.Writer) TableWriter {
        return .{
            .buf = buf,
            .inner = writer,
        };
    }

    pub fn writeHeader(self: *TableWriter, comptime cols: []const Col) !void {
        try self.beginRow();

        inline for (cols) |col| {
            try self.writeValue(col.name, col.width);
        }

        try self.endRow();
    }

    pub fn writeSeparator(self: *TableWriter, comptime cols: []const Col) !void {
        try self.inner.writeAll("\n|");

        inline for (cols) |col| {
            try self.inner.writeAll(("-" ** (col.width + 2)) ++ "|");
        }
    }

    pub fn writeRow(self: *TableWriter, it: anytype, comptime cols: []const Col) !void {
        try self.beginRow();

        inline for (cols) |col| {
            try self.writeValue(@field(it, col.name), col.width);
        }

        try self.endRow();
    }

    pub fn beginRow(self: *TableWriter) !void {
        if (self.row > 0) try self.inner.writeByte('\n');
        try self.inner.writeAll("| ");
    }

    pub fn endRow(self: *TableWriter) !void {
        try self.inner.writeAll(" |");
        self.col = 0;
        self.row += 1;
    }

    pub fn writeValue(self: *TableWriter, value: anytype, width: usize) !void {
        if (width > self.buf.len) return error.BufferTooSmall;

        if (self.col > 0) try self.inner.writeAll(" | ");
        defer self.col += 1;

        const chunk = try self.bufPrint(value);

        if (chunk.len > width) {
            try self.inner.writeAll(chunk[0 .. width - 1]);
            try self.inner.writeByte('.');
        } else {
            try self.inner.writeAll(chunk[0..@min(chunk.len, width)]);

            if (chunk.len < width) {
                try self.inner.splatByteAll(' ', width - chunk.len);
            }
        }
    }

    fn bufPrint(self: *TableWriter, value: anytype) ![]const u8 {
        if (meta.isString(@TypeOf(value))) {
            return value;
        }

        return switch (@typeInfo(@TypeOf(value))) {
            .optional => if (value) |v| self.bufPrint(v) else "",
            .@"enum" => @tagName(value),
            else => std.fmt.bufPrint(self.buf, "{}", .{value}),
        };
    }
};

test expectTable {
    const Person = struct { name: []const u8, age: u32, salary: ?u32 };

    const items: []const Person = &.{
        .{ .name = "John", .age = 21, .salary = 1000 },
        .{ .name = "Jane", .age = 23, .salary = 2000 },
        .{ .name = "James", .age = 25, .salary = null },
    };

    try expectTable(items,
        \\| name | age |
        \\|------|-----|
        \\| John | 21  |
        \\| Jane | 23  |
        \\| Jam. | 25  |
    );

    try expectTable(items,
        \\| name  | age |
        \\|-------|-----|
        \\| John  | 21  |
        \\| Jane  | 23  |
        \\| James | 25  |
    );

    try expectTable(items,
        \\| name | salary |
        \\|------|--------|
        \\| John | 1000   |
        \\| Jane | 2000   |
        \\| Jam. |        |
    );
}

/// Shorthand for MockClient.init() + &mock.interface
pub fn httpClient() !struct { *MockClient, *http.Client } {
    const mock = try MockClient.init(std.testing.allocator);

    return .{
        mock,
        &mock.interface,
    };
}

test httpClient {
    const mock, const http_client = try httpClient();
    defer mock.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try mock.expectNext("200 GET /foo", "{\"bar\":\"baz\"}");
    const res = try http_client.request(arena.allocator(), .{ .method = .GET, .url = "/foo" });

    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("{\"bar\":\"baz\"}", res.body);
}

pub const MockClient = struct {
    interface: http.Client,
    fixtures: std.array_list.Managed(struct { std.http.Method, []const u8, std.http.Status, []const u8 }),

    pub fn init(gpa: std.mem.Allocator) !*MockClient {
        const self = try gpa.create(MockClient);

        self.* = .{
            .interface = .{
                .make_request = &make_request,
                .config = &.{},
            },
            .fixtures = std.array_list.Managed(struct { std.http.Method, []const u8, std.http.Status, []const u8 }).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *MockClient) void {
        const gpa = self.fixtures.allocator;
        self.fixtures.deinit();
        gpa.destroy(self);
    }

    fn make_request(client: *http.Client, arena: std.mem.Allocator, options: http.RequestOptions) !http.ClientResponse {
        const self: *MockClient = @fieldParentPtr("interface", client);
        const method, const url, const status, const body = self.fixtures.orderedRemove(0);

        try std.testing.expectEqual(method, options.method);
        try std.testing.expectEqualStrings(url, options.url);

        return .{
            .arena = arena,
            .headers = .empty,
            .status = status,
            .body = body,
        };
    }

    pub fn expectNext(self: *MockClient, comptime req: []const u8, comptime res: []const u8) !void {
        var it = std.mem.splitScalar(u8, req, ' ');
        const status: std.http.Status = @enumFromInt(try std.fmt.parseInt(u8, it.next().?, 10));
        const method = std.meta.stringToEnum(std.http.Method, it.next().?).?;
        const url = it.next().?;

        try self.fixtures.append(.{ method, url, status, res });
    }
};
