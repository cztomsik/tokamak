const std = @import("std");
const dusty = @import("dusty");
const http = @import("http.zig");
const Server = @import("../server.zig").Server;

pub const Backend = struct {
    server: *Server,
    native: dusty.Server(Handler),
    listener: dusty.Listener,
    handler: Handler = undefined,
    running: ?std.Io.Future(@typeInfo(@TypeOf(start)).@"fn".return_type.?) = null,

    pub fn init(server: *Server) !Backend {
        const options = server.options;
        return .{
            .server = server,
            .native = dusty.Server(Handler).init(server.gpa, server.io, .{
                .request = .{ .max_body_size = options.request.max_body_size, .max_query_count = options.request.max_query_count },
                .timeout = .{ .request = options.timeout.request, .keepalive = options.timeout.keepalive },
                .max_connections = options.max_connections,
                .trusted_proxy_hops = options.trusted_proxy_hops,
            }, undefined),
            .listener = .{ .address = .{ .ip = try std.Io.net.IpAddress.parse(options.listen.hostname, options.listen.port) } },
        };
    }

    pub fn deinit(self: *Backend) void {
        self.stop();
        self.native.deinit();
    }

    pub fn start(self: *Backend) !void {
        self.handler = .{ .server = self.server };
        self.native.ctx = &self.handler;
        self.native.config.listen = &.{self.listener};
        self.native.router.any("/", Handler.handle);
        self.native.router.any("/*", Handler.handle);
        try self.native.run();
    }

    pub fn startInBackground(self: *Backend) !void {
        if (self.running != null) return error.AlreadyRunning;
        self.running = try self.server.io.concurrent(Backend.start, .{self});
        errdefer self.stop();
        try self.native.ready.wait(self.server.io);
    }

    pub fn stop(self: *Backend) void {
        if (self.running) |*future| {
            _ = future.cancel(self.server.io) catch {};
            self.running = null;
        }
    }

    pub fn port(self: *const Backend) u16 {
        return self.native.address.ip.getPort();
    }
};

const Handler = struct {
    server: *Server,

    pub fn handle(self: *Handler, req: *dusty.Request, res: *dusty.Response) !void {
        const method = std.meta.stringToEnum(std.http.Method, req.method.name()) orelse return error.UnsupportedMethod;
        var query: std.StringHashMapUnmanaged([]const u8) = .empty;
        if (std.mem.indexOfScalar(u8, req.url, '?')) |index| {
            var pairs = std.mem.splitScalar(u8, req.url[index + 1 ..], '&');
            var pair_count: usize = 0;
            while (pairs.next()) |pair| {
                if (pair.len == 0) continue;
                pair_count += 1;
                if (pair_count > self.server.options.request.max_query_count) return error.TooManyQueryParams;
                const separator = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
                const key = try dusty.Request.urlUnescape(req.arena, pair[0..separator]);
                const value = if (separator < pair.len) try dusty.Request.urlUnescape(req.arena, pair[separator + 1 ..]) else "";
                try query.put(req.arena, key, value);
            }
        }
        var request: http.Request = .{
            .method = method,
            .url = req.url[0 .. std.mem.indexOfScalar(u8, req.url, '?') orelse req.url.len],
            .query = query,
            .arena = req.arena,
            .native = req,
            .body_fn = body,
            .header_fn = requestHeader,
        };
        var response: http.Response = .{
            .native = res,
            .header_fn = responseHeader,
            .stream_fn = eventStream,
        };
        try self.server.dispatch(&request, &response);
        if (response.streaming) return;
        res.status = @fromBackingInt(@intCast(response.status));
        res.body = response.body;
        res.content_type = if (response.content_type) |ct| switch (ct) {
            .text => .text,
            .json => .json,
            .html => .html,
        } else null;
    }
};

fn body(native: *anyopaque) anyerror!?[]const u8 {
    const req: *dusty.Request = @ptrCast(@alignCast(native));
    return req.body();
}

fn requestHeader(native: *anyopaque, name: []const u8) ?[]const u8 {
    const req: *dusty.Request = @ptrCast(@alignCast(native));
    return req.headers.get(name);
}

fn responseHeader(native: *anyopaque, name: []const u8, value: []const u8) anyerror!void {
    const res: *dusty.Response = @ptrCast(@alignCast(native));
    try res.header(name, value);
}

const Stream = struct {
    native: dusty.EventStream,
    buffer: [4096]u8,
};

fn eventStream(native: *anyopaque) anyerror!http.EventStream {
    const res: *dusty.Response = @ptrCast(@alignCast(native));
    const stream = try res.arena.create(Stream);
    stream.* = .{ .native = undefined, .buffer = undefined };
    stream.native = try res.startEventStream(&stream.buffer);
    return .{ .native = stream, .send_fn = sendEvent, .end_fn = endEvent };
}

fn sendEvent(native: *anyopaque, data: []const u8) anyerror!void {
    const stream: *Stream = @ptrCast(@alignCast(native));
    try stream.native.send(data, .{});
}

fn endEvent(native: *anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(native));
    stream.native.body.end() catch {};
}
