const std = @import("std");
const http = @import("http.zig");

pub fn httpClient() !struct { http.Client, *MockClientBackend } {
    const http_client = try http.Client.initWithBackend(MockClientBackend, std.testing.allocator, .{});

    return .{
        http_client,
        @ptrCast(@alignCast(http_client.backend.ctx)),
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
