const std = @import("std");
const client = @import("client.zig");

pub const Client = struct {
    fixtures: std.ArrayList(struct { std.http.Method, []const u8, client.Response }),

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .fixtures = .init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.fixtures.deinit();
    }

    pub fn expectNext(self: *Client, comptime req: []const u8, comptime res: []const u8) !void {
        var it = std.mem.splitScalar(u8, req, ' ');
        const status = it.next().?;
        const method = std.meta.stringToEnum(std.http.Method, it.next().?).?;
        const url = it.next().?;

        const resp: client.Response = .{
            .arena = undefined,
            .headers = undefined,
            .status = @enumFromInt(try std.fmt.parseInt(u8, status, 10)),
            .body = res,
        };

        try self.fixtures.append(.{ method, url, resp });
    }

    pub fn request(self: *Client, _: std.mem.Allocator, options: client.ReqOptions) !client.Response {
        const method, const url, const res = self.fixtures.pop().?;

        try std.testing.expectEqual(method, options.method);
        try std.testing.expectEqualStrings(url, options.url);

        return res;
    }
};

test {
    var mock_client = Client.init(std.testing.allocator);
    defer mock_client.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try mock_client.expectNext("200 GET /foo", "{\"bar\":\"baz\"}");
    const res = try mock_client.request(arena.allocator(), .{ .method = .GET, .url = "/foo" });

    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("{\"bar\":\"baz\"}", res.body);
}
