const std = @import("std");

pub const Config = struct {
    base_url: ?[]const u8 = null,
};

pub const Options = struct {
    base_url: ?[]const u8 = null,
    method: std.http.Method = .GET,
    url: []const u8 = "",
    headers: []const std.http.Header = &.{},
    body: ?Body = null,
    max_len: usize = 64 * 1024,
};

pub const Body = struct {
    ctx: *const anyopaque,
    render: *const fn (ctx: *const anyopaque, writer: std.io.AnyWriter) anyerror!void,

    pub fn json(ptr: anytype) Body {
        const H = struct {
            fn stringify(ctx: @TypeOf(ptr), writer: std.io.AnyWriter) anyerror!void {
                try std.json.stringify(ctx, .{}, writer);
            }
        };

        return .{
            .ctx = @ptrCast(ptr),
            .render = @ptrCast(&H.stringify),
        };
    }
};

pub const HttpClient = struct {
    config: Config,
    inner: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: Config) !HttpClient {
        return .{
            .config = config,
            .inner = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.inner.deinit();
    }

    pub fn request(self: *HttpClient, arena: std.mem.Allocator, options: Options) !Response {
        var buf: [4 * 1024]u8 = undefined;
        var remaining: []u8 = &buf;

        const url = try std.Uri.resolve_inplace(
            if (options.base_url orelse self.config.base_url) |base| try std.Uri.parse(base) else .{ .scheme = "http" },
            options.url,
            &remaining,
        );

        var req = try self.inner.open(options.method, url, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = options.headers,
            .server_header_buffer = remaining,
        });
        defer req.deinit();

        if (options.body != null) {
            req.transfer_encoding = .chunked;
        }

        try req.send();

        if (options.body) |body| {
            var w = req.writer();
            try body.render(body.ctx, w.any());
            try req.finish();
        }

        try req.wait();

        var headers: std.StringHashMapUnmanaged([]const u8) = .{};
        var it = req.response.iterateHeaders();
        while (it.next()) |h| {
            try headers.put(arena, h.name, h.value);
        }

        return .{
            .arena = arena,
            .status = req.response.status,
            .headers = headers,
            .body = try req.reader().readAllAlloc(arena, options.max_len),
        };
    }
};

pub const Response = struct {
    arena: std.mem.Allocator,
    status: std.http.Status,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: []const u8,

    pub fn json(self: Response, comptime T: type) !T {
        errdefer std.log.err("Failed to parse {s}: {s}", .{ @typeName(T), self.body[0..@min(self.body.len, 512)] });

        return std.json.parseFromSliceLeaky(T, self.arena, self.body, .{
            .ignore_unknown_fields = true,
        });
    }
};

// TODO: beforeAll/afterAll?
test {
    const tk = @import("main.zig");

    const routes: []const tk.Route = &.{
        .get("/ping", tk.send("pong")),
        // .post("/echo", tk.meta.dupe),
    };

    var server = try tk.Server.init(std.testing.allocator, routes, .{});
    defer server.deinit();

    var thread = try std.Thread.spawn(.{}, tk.Server.start, .{server});
    defer thread.join();
    defer server.stop();

    var client = try HttpClient.init(std.testing.allocator, .{ .base_url = "http://localhost:8080/" });
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res1 = try client.request(arena.allocator(), .{ .url = "/ping" });
    try std.testing.expectEqual(.ok, res1.status);
    try std.testing.expectEqualStrings("pong", res1.body);
}
