const std = @import("std");
const log = std.log.scoped(.server);
const Injector = @import("injector.zig").Injector;
const Route = @import("router.zig").Route;
const Request = @import("request.zig").Request;
const Params = @import("request.zig").Params;
const Response = @import("response.zig").Response;

pub const Options = struct {
    public_url: ?[]const u8 = null,
    hostname: []const u8 = "127.0.0.1",
    port: u16,
    n_threads: usize = 8,
    keep_alive: bool = true,
};

pub const Handler = fn (*Context) anyerror!void;

pub const Context = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    req: Request,
    res: Response,
    current: Route,
    params: Params,
    injector: Injector,

    fn init(self: *Context, allocator: std.mem.Allocator, server: *Server, http: *std.http.Server) !void {
        const raw = http.receiveHead() catch |e| {
            if (e == error.HttpHeadersUnreadable) return error.HttpConnectionClosing;
            return e;
        };

        self.* = .{
            .server = server,
            .allocator = allocator,
            .req = try Request.init(allocator, raw),
            .res = .{ .req = &self.req, .headers = std.ArrayList(std.http.Header).init(allocator) },
            .current = .{ .children = server.routes },
            .params = .{},
            .injector = Injector.from(self),
        };

        self.res.keep_alive = server.options.keep_alive;
    }

    pub fn recur(self: *Context) !void {
        for (self.current.children) |route| {
            if (route.match(&self.req)) |params| {
                self.current = route;
                self.params = params;

                if (route.handler) |handler| {
                    try handler(self);
                } else {
                    try self.recur();
                }
            }

            if (self.res.responded) return;
        }
    }

    pub fn recurScoped(self: *Context, ctx: anytype) !void {
        const prev = self.injector;
        defer self.injector = prev;
        self.injector = Injector.init(ctx, &prev);
    }
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    allocator: std.mem.Allocator,
    routes: []const Route,
    options: Options,

    net: std.net.Server,
    threads: []std.Thread,
    mutex: std.Thread.Mutex = .{},
    stopping: std.Thread.ResetEvent = .{},
    stopped: std.Thread.ResetEvent = .{},

    /// Run the server, blocking the current thread.
    pub fn run(allocator: std.mem.Allocator, routes: []const Route, options: Options) !void {
        var server = try start(allocator, routes, options);
        defer server.deinit();

        server.wait();
    }

    /// Start a new server.
    pub fn start(allocator: std.mem.Allocator, routes: []const Route, options: Options) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        const address = try std.net.Address.parseIp(options.hostname, options.port);

        var net = try address.listen(.{ .reuse_address = true });
        errdefer net.deinit();

        const threads = try allocator.alloc(std.Thread, options.n_threads);
        errdefer allocator.free(threads);

        self.* = .{
            .allocator = allocator,
            .routes = routes,
            .options = options,

            .net = net,
            .threads = threads,
        };

        for (threads) |*t| {
            t.* = std.Thread.spawn(.{}, loop, .{self}) catch @panic("thread spawn");
        }

        return self;
    }

    /// Wait for the server to stop.
    pub fn wait(self: *Server) void {
        self.stopped.wait();
    }

    /// Stop and deinitialize the server.
    pub fn deinit(self: *Server) void {
        self.stopping.set();

        if (std.net.tcpConnectToAddress(self.net.listen_address)) |c| c.close() else |_| {}
        self.net.deinit();

        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);

        self.stopped.set();
        self.allocator.destroy(self);
    }

    fn accept(self: *Server) ?std.net.Server.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stopping.isSet()) return null;

        const conn = self.net.accept() catch |e| {
            if (self.stopping.isSet()) return null;

            // TODO: not sure what we can do here
            //       but we should not just throw because that would crash the thread silently
            std.debug.panic("accept: {}", .{e});
        };

        const timeout = std.posix.timeval{
            .tv_sec = @as(i32, 5),
            .tv_usec = @as(i32, 0),
        };

        std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        return conn;
    }

    fn loop(server: *Server) void {
        var arena = std.heap.ArenaAllocator.init(server.allocator);
        defer arena.deinit();

        accept: while (server.accept()) |conn| {
            defer conn.stream.close();

            var buf: [10 * 1024]u8 = undefined;
            var http = std.http.Server.init(conn, &buf);

            while (http.state == .ready) {
                defer _ = arena.reset(.{ .retain_with_limit = 8 * 1024 * 1024 });

                var ctx: Context = undefined;
                ctx.init(arena.allocator(), server, &http) catch |e| {
                    if (e != error.HttpConnectionClosing) log.err("context: {}", .{e});
                    continue :accept;
                };

                defer {
                    if (!ctx.res.responded) ctx.res.sendStatus(.no_content) catch {};
                    ctx.res.out.?.end() catch {};
                }

                ctx.recur() catch |e| {
                    log.err("err: {}", .{e});
                    ctx.res.sendError(e) catch {};
                    continue :accept;
                };
            }
        }
    }
};
