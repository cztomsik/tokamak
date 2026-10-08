const std = @import("std");
const httpz = @import("httpz");
const http = @import("http.zig");
const Server = @import("../server.zig").Server;

pub const Backend = struct {
    server: *Server,
    native: httpz.Server(Handler),
    thread: ?std.Thread = null,

    pub fn init(server: *Server) !Backend {
        const options = server.options;
        var config: httpz.Config = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse(options.listen.hostname, options.listen.port) },
            .request = .{ .max_body_size = options.request.max_body_size, .max_query_count = options.request.max_query_count },
        };
        config.timeout.request = if (options.timeout.request) |duration| try timeoutSeconds(duration) else null;
        config.timeout.keepalive = if (options.timeout.keepalive) |duration| try timeoutSeconds(duration) else null;
        return .{
            .server = server,
            .native = try httpz.Server(Handler).init(server.io, server.gpa, config, .{ .server = server }),
        };
    }

    pub fn deinit(self: *Backend) void {
        self.stop();
        self.native.deinit();
    }

    pub fn start(self: *Backend) !void {
        try self.native.listen();
    }

    pub fn startInBackground(self: *Backend) !void {
        if (self.thread != null) return error.AlreadyRunning;
        const thread = try self.native.listenInNewThread();
        if (self.native._listener == null) {
            thread.join();
            return error.ListenFailed;
        }
        self.thread = thread;
    }

    pub fn stop(self: *Backend) void {
        if (self.thread) |thread| {
            self.native.stop();
            thread.join();
            self.thread = null;
        } else if (self.native._listener != null) {
            self.native.stop();
        }
    }

    pub fn port(self: *const Backend) u16 {
        const listener = self.native._listener orelse return self.server.options.listen.port;
        var address: std.posix.sockaddr.storage = undefined;
        var len: std.posix.socklen_t = @sizeOf(@TypeOf(address));
        if (std.posix.errno(std.posix.system.getsockname(listener, @ptrCast(&address), &len)) != .SUCCESS) return self.server.options.listen.port;
        return switch (address.family) {
            std.posix.AF.INET => std.mem.bigToNative(u16, @as(*const std.posix.sockaddr.in, @ptrCast(&address)).port),
            std.posix.AF.INET6 => std.mem.bigToNative(u16, @as(*const std.posix.sockaddr.in6, @ptrCast(&address)).port),
            else => self.server.options.listen.port,
        };
    }
};

fn timeoutSeconds(duration: std.Io.Duration) !u32 {
    if (duration.nanoseconds < 0) return error.InvalidTimeout;
    const seconds = @divTrunc(duration.nanoseconds, std.time.ns_per_s);
    const rounded = seconds + @intFromBool(@rem(duration.nanoseconds, std.time.ns_per_s) != 0);
    return std.math.cast(u32, rounded) orelse error.InvalidTimeout;
}

const Handler = struct {
    server: *Server,

    pub fn handle(self: Handler, req: *httpz.Request, res: *httpz.Response) void {
        handleRequest(self.server, req, res) catch {
            if (res.written) return;
            res.status = 500;
            res.body = "Internal Server Error";
            res.content_type = .TEXT;
        };
    }
};

fn handleRequest(server: *Server, req: *httpz.Request, res: *httpz.Response) !void {
    const method: std.http.Method = switch (req.method) {
        .GET => .GET,
        .HEAD => .HEAD,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .OPTIONS => .OPTIONS,
        .CONNECT => .CONNECT,
        .OTHER => std.meta.stringToEnum(std.http.Method, req.method_string) orelse {
            res.status = 501;
            res.body = "Not Implemented";
            return;
        },
    };

    var query: std.StringHashMapUnmanaged([]const u8) = .empty;
    var pairs = std.mem.splitScalar(u8, req.url.query, '&');
    var pair_count: usize = 0;
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        pair_count += 1;
        if (pair_count > server.options.request.max_query_count) return error.TooManyQueryParams;
    }
    const native_query = try req.query();
    var iterator = native_query.iterator();
    while (iterator.next()) |entry| {
        try query.put(req.arena, entry.key, entry.value);
    }

    var request: http.Request = .{
        .method = method,
        .url = req.url.path,
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
    try server.dispatch(&request, &response);
    if (response.streaming) return;
    res.status = response.status;
    res.body = response.body;
    res.content_type = if (response.content_type) |content_type| switch (content_type) {
        .text => .TEXT,
        .json => .JSON,
        .html => .HTML,
    } else null;
}

fn body(native: *anyopaque) anyerror!?[]const u8 {
    const req: *httpz.Request = @ptrCast(@alignCast(native));
    return req.body();
}

fn requestHeader(native: *anyopaque, name: []const u8) ?[]const u8 {
    const req: *httpz.Request = @ptrCast(@alignCast(native));
    const normalized = req.arena.dupe(u8, name) catch return null;
    _ = std.ascii.lowerString(normalized, name);
    return req.header(normalized);
}

fn responseHeader(native: *anyopaque, name: []const u8, value: []const u8) anyerror!void {
    const res: *httpz.Response = @ptrCast(@alignCast(native));
    res.header(name, value);
}

const Stream = struct {
    io: std.Io,
    native: std.Io.net.Stream,
};

fn eventStream(native: *anyopaque) anyerror!http.EventStream {
    const res: *httpz.Response = @ptrCast(@alignCast(native));
    const stream = try res.arena.create(Stream);
    stream.* = .{ .io = res.conn.io, .native = try res.startEventStreamSync() };
    return .{ .native = stream, .send_fn = sendEvent, .end_fn = endEvent };
}

fn sendEvent(native: *anyopaque, data: []const u8) anyerror!void {
    const stream: *Stream = @ptrCast(@alignCast(native));
    var buffer: [4096]u8 = undefined;
    var writer = stream.native.writer(stream.io, &buffer);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| try writer.interface.print("data: {s}\n", .{line});
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn endEvent(native: *anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(native));
    stream.native.close(stream.io);
}
