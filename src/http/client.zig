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
    max_len: usize = 64 * 1024,
    timeout: ?usize = 60, // TODO: given how std.http.Client reads, it's better to wait for async + timers
};

pub const RequestBody = struct {
    ctx: *const anyopaque,
    render: *const fn (ctx: *const anyopaque, writer: std.io.AnyWriter) anyerror!void,

    pub fn json(ptr: anytype) RequestBody {
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
    config: Config,
    backend: ClientBackend,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        return initWithBackend(DefaultBackend, allocator, config);
    }

    pub fn initWithBackend(comptime B: type, allocator: std.mem.Allocator, config: Config) !Client {
        const backend = try B.init(allocator);

        return .{
            .config = config,
            .backend = meta.upcast(backend, ClientBackend),
        };
    }

    pub fn deinit(self: *Client) void {
        self.backend.deinit();
    }

    pub fn request(self: *Client, arena: std.mem.Allocator, options: RequestOptions) !Response {
        var opts = options;
        opts.base_url = opts.base_url orelse self.config.base_url;

        return self.backend.request(arena, opts);
    }
};

pub const ClientBackend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = std.http.Client.ConnectError || std.http.Client.RequestError;

    pub const VTable = struct {
        request: *const fn (cx: *anyopaque, arena: std.mem.Allocator, options: RequestOptions) Error!Response,
        deinit: *const fn (cx: *anyopaque) void,
    };

    pub fn request(self: *ClientBackend, arena: std.mem.Allocator, options: RequestOptions) !Response {
        return self.vtable.request(self.context, arena, options);
    }

    pub fn deinit(self: *ClientBackend) void {
        self.vtable.deinit(self.context);
    }
};

pub const DefaultBackend = struct {
    std_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) !*DefaultBackend {
        const self = try allocator.create(DefaultBackend);

        self.* = .{
            .std_client = .{ .allocator = allocator },
        };

        return self;
    }

    pub fn deinit(self: *DefaultBackend) void {
        const allocator = self.std_client.allocator;
        self.std_client.deinit();
        allocator.destroy(self);
    }

    pub fn request(self: *DefaultBackend, arena: std.mem.Allocator, options: RequestOptions) !Response {
        var buf: [4 * 1024]u8 = undefined;
        var remaining: []u8 = &buf;

        const url = try std.Uri.resolve_inplace(
            if (options.base_url) |base| try std.Uri.parse(base) else .{ .scheme = "http" },
            options.url,
            &remaining,
        );
        const content_type: ?[]const u8 = blk: {
            const headers = options.headers;
            if (headers.len == 0) break :blk null;
            for (headers) |h| {
                if (std.mem.eql(u8, h.name, "Content-Type")) break :blk h.value;
            }
            break :blk null;
        };

        var req = try self.std_client.open(options.method, url, .{
            .headers = .{
                .content_type = .{ .override = content_type orelse "application/json" },
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

    var client = try Client.init(std.testing.allocator, .{ .base_url = "http://localhost:8080/" });
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res1 = try client.request(arena.allocator(), .{ .url = "/ping" });
    try std.testing.expectEqual(.ok, res1.status);
    try std.testing.expectEqualStrings("pong", res1.body);
}
