const std = @import("std");
const meta = @import("meta.zig");
const serde = @import("serde.zig");
const http = @import("http.zig");
const util = @import("util.zig");

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
    var wb: std.Io.Writer.Allocating = .init(allocator);
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
        var cols: [util.countScalar(u8, header, '|') - 1]serde.table.Col = undefined;
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

    var wb: std.Io.Writer.Allocating = .init(allocator);
    defer wb.deinit();

    var buf: [header.len]u8 = undefined;
    var w = serde.table.Writer.init(&buf, &wb.writer, .{ .columns = &cols });
    try serde.serialize(&w, items);

    try std.testing.expectEqualStrings(expected, wb.written());
}

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
    allocator: std.mem.Allocator,
    fixtures: std.ArrayList(struct { std.http.Method, []const u8, std.http.Status, []const u8 }),

    pub fn init(gpa: std.mem.Allocator) !*MockClient {
        const self = try gpa.create(MockClient);

        self.* = .{
            .interface = .{ .make_request = &make_request },
            .allocator = gpa,
            .fixtures = .empty,
        };

        return self;
    }

    pub fn deinit(self: *MockClient) void {
        const gpa = self.allocator;
        self.fixtures.deinit(gpa);
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

        try self.fixtures.append(self.allocator, .{ method, url, status, res });
    }
};
