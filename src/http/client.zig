const std = @import("std");
const meta = @import("../meta.zig");

pub const Config = struct {
    base_url: ?[]const u8 = null,
};

pub const RequestOptions = struct {
    base_url: ?[]const u8 = null,
    method: std.http.Method = .GET,
    url: []const u8 = "",
    headers: []const std.http.Header = &.{},
    body: ?RequestBody = null,
    max_len: usize = 1024 * 1024,
    timeout: ?usize = 60, // TODO: given how std.http.Client reads, it's better to wait for async + timers
};

pub const RequestBody = struct {
    ctx: *const anyopaque,
    content_type: []const u8,
    render: *const fn (ctx: *const anyopaque, writer: std.io.AnyWriter) anyerror!void,

    pub fn write(self: RequestBody, writer: std.io.AnyWriter) !void {
        try self.render(self.ctx, writer);
    }

    pub fn json(ptr: anytype) RequestBody {
        const H = struct {
            fn stringify(ctx: @TypeOf(ptr), writer: std.io.AnyWriter) anyerror!void {
                try std.json.stringify(ctx, .{}, writer);
            }
        };

        return .{
            .ctx = @ptrCast(ptr),
            .content_type = "application/json",
            .render = @ptrCast(&H.stringify),
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

pub const Client = struct {
    make_request: *const fn (*Client, std.mem.Allocator, RequestOptions) Error!Response,
    config: *const Config,

    // TODO
    const Error = anyerror;

    pub fn request(self: *Client, arena: std.mem.Allocator, options: RequestOptions) !Response {
        var opts = options;
        opts.base_url = opts.base_url orelse self.config.base_url;

        return self.make_request(self, arena, opts);
    }

    pub fn get(self: *Client, arena: std.mem.Allocator, url: []const u8) !Response {
        return self.request(arena, .{ .method = .GET, .url = url });
    }

    pub fn post(self: *Client, arena: std.mem.Allocator, url: []const u8, body: ?RequestBody) !Response {
        return self.request(arena, .{ .method = .POST, .url = url, .body = body });
    }
};

pub const StdClient = struct {
    interface: Client,
    std_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: ?*const Config) !@This() {
        return .{
            .interface = .{
                .make_request = &make_request,
                .config = config orelse &.{},
            },
            .std_client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *StdClient) void {
        self.std_client.deinit();
    }

    fn make_request(client: *Client, arena: std.mem.Allocator, options: RequestOptions) !Response {
        const self: *@This() = @fieldParentPtr("interface", client);
        var buf: []u8 = try arena.alloc(u8, 8 * 1024);

        const url = try std.Uri.resolve_inplace(
            if (options.base_url) |base| try std.Uri.parse(base) else .{ .scheme = "http" },
            options.url,
            &buf,
        );

        var req = try self.std_client.open(options.method, url, .{
            .headers = .{
                .content_type = if (options.body) |b| .{ .override = b.content_type } else .default,
            },
            .extra_headers = options.headers,
            .server_header_buffer = buf,
        });
        defer req.deinit();

        if (options.body != null) {
            req.transfer_encoding = .chunked;
        }

        try req.send();

        if (options.body) |body| {
            try body.write(req.writer().any());
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

// TODO: beforeAll/afterAll?
test {
    const tk = @import("../main.zig");

    const routes: []const tk.Route = &.{
        .get("/ping", tk.send("pong")),
        // .post("/echo", tk.meta.dupe),
    };

    var server = try tk.Server.init(std.testing.allocator, routes, .{});
    defer server.deinit();

    var thread = try std.Thread.spawn(.{}, tk.Server.start, .{&server});
    defer thread.join();
    defer server.stop();

    var std_client = try StdClient.init(std.testing.allocator, &.{ .base_url = "http://localhost:8080/" });
    defer std_client.deinit();

    const client = &std_client.interface;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res1 = try client.request(arena.allocator(), .{ .url = "/ping" });
    try std.testing.expectEqual(.ok, res1.status);
    try std.testing.expectEqualStrings("pong", res1.body);
}
