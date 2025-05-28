const std = @import("std");
const meta = @import("meta.zig");
const mem = @import("mem.zig");
const http = @import("http.zig");

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

    var res = std.ArrayList(u8).init(std.testing.allocator);
    defer res.deinit();

    var buf: [header.len]u8 = undefined;
    var w = TableWriter.init(&buf, res.writer().any());

    try w.writeHeader(&cols);
    try w.writeSeparator(&cols);

    for (items) |it| {
        try w.writeRow(it, &cols);
    }

    try std.testing.expectEqualStrings(expected, res.items);
}

const Col = struct {
    name: []const u8,
    width: u32,
};

const TableWriter = struct {
    buf: []u8,
    inner: std.io.AnyWriter,
    row: usize = 0,
    col: usize = 0,

    pub fn init(buf: []u8, writer: std.io.AnyWriter) TableWriter {
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

        if (comptime meta.isString(@TypeOf(value))) {
            if (value.len > width) {
                try self.inner.writeAll(value[0 .. width - 1]);
                try self.inner.writeByte('.');
            } else {
                try self.inner.writeAll(value[0..@min(value.len, width)]);
            }
            if (value.len < width) try self.inner.writeByteNTimes(' ', width - value.len);
        } else {
            @memset(self.buf[0..width], ' ');
            _ = try std.fmt.bufPrint(self.buf, "{}", .{value});
            try self.inner.writeAll(self.buf[0..width]);
        }
    }
};

test expectTable {
    const Person = struct { name: []const u8, age: u32, salary: u32 };

    const items: []const Person = &.{
        .{ .name = "John", .age = 21, .salary = 1000 },
        .{ .name = "Jane", .age = 23, .salary = 2000 },
        .{ .name = "James", .age = 25, .salary = 3000 },
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
        \\| Jam. | 3000   |
    );
}

pub fn httpClient() !struct { http.Client, *MockClientBackend } {
    const http_client = try http.Client.initWithBackend(MockClientBackend, std.testing.allocator, .{});

    return .{
        http_client,
        @ptrCast(@alignCast(http_client.backend.context)),
    };
}

test httpClient {
    var http_client, var mock = try httpClient();
    defer http_client.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try mock.expectNext("200 GET /foo", "{\"bar\":\"baz\"}");
    const res = try http_client.request(arena.allocator(), .{ .method = .GET, .url = "/foo" });

    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("{\"bar\":\"baz\"}", res.body);
}

pub const MockClientBackend = struct {
    fixtures: std.ArrayList(struct { std.http.Method, []const u8, std.http.Status, []const u8 }),

    pub fn init(allocator: std.mem.Allocator) !*MockClientBackend {
        const self = try allocator.create(MockClientBackend);

        self.* = .{
            .fixtures = .init(allocator),
        };

        return self;
    }

    pub fn deinit(cx: *anyopaque) void {
        const self: *MockClientBackend = @ptrCast(@alignCast(cx));
        const allocator = self.fixtures.allocator;
        self.fixtures.deinit();
        allocator.destroy(self);
    }

    pub fn request(cx: *anyopaque, arena: std.mem.Allocator, options: http.RequestOptions) !http.ClientResponse {
        const self: *MockClientBackend = @ptrCast(@alignCast(cx));
        const method, const url, const status, const body = self.fixtures.orderedRemove(0);

        try std.testing.expectEqual(method, options.method);
        try std.testing.expectEqualStrings(url, options.url);

        return .{
            .arena = arena,
            .headers = undefined,
            .status = status,
            .body = body,
        };
    }

    pub fn expectNext(self: *MockClientBackend, comptime req: []const u8, comptime res: []const u8) !void {
        var it = std.mem.splitScalar(u8, req, ' ');
        const status: std.http.Status = @enumFromInt(try std.fmt.parseInt(u8, it.next().?, 10));
        const method = std.meta.stringToEnum(std.http.Method, it.next().?).?;
        const url = it.next().?;

        try self.fixtures.append(.{ method, url, status, res });
    }
};
