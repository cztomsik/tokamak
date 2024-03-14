const std = @import("std");
const log = std.log.scoped(.server);
const Injector = @import("injector.zig").Injector;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Options = struct {
    injector: Injector = .{},
    hostname: []const u8 = "127.0.0.1",
    port: u16,
    n_threads: usize = 8,
    keep_alive: bool = true,
};

pub const Handler = fn (*Context) anyerror!void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    req: Request,
    res: Response,
    injector: Injector,
    stack: std.BoundedArray(*const fn (*Context) anyerror!void, 64) = .{},

    fn init(self: *Context, allocator: std.mem.Allocator, server: *Server, http: *std.http.Server) !void {
        const raw = try http.receiveHead();

        self.* = .{
            .allocator = allocator,
            .req = try Request.init(allocator, raw),
            .res = .{ .req = &self.req },
            .injector = .{ .parent = &server.injector },
        };

        self.res.keep_alive = server.keep_alive;

        try self.injector.push(&self.allocator);
        try self.injector.push(&self.req);
        try self.injector.push(&self.res);
        try self.injector.push(self);
    }

    /// Run the next middleware or handler.
    pub inline fn next(self: *Context) !void {
        if (self.stack.popOrNull()) |f| {
            return f(self);
        }
    }

    pub fn wrap(fun: anytype) Handler {
        if (@TypeOf(fun) == Handler) return fun;

        const H = struct {
            fn handle(ctx: *Context) anyerror!void {
                return ctx.res.send(ctx.injector.call(fun, .{}));
            }
        };
        return H.handle;
    }
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    allocator: std.mem.Allocator,
    injector: Injector,
    net: std.net.Server,
    threads: []std.Thread,
    mutex: std.Thread.Mutex = .{},
    stopping: std.Thread.ResetEvent = .{},
    stopped: std.Thread.ResetEvent = .{},
    handler: *const Handler,
    keep_alive: bool,

    /// Start a new server.
    pub fn start(allocator: std.mem.Allocator, handler: anytype, options: Options) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        const address = try std.net.Address.parseIp(options.hostname, options.port);

        var net = try address.listen(.{ .reuse_address = true });
        errdefer net.deinit();

        const threads = try allocator.alloc(std.Thread, options.n_threads);
        errdefer allocator.free(threads);

        self.* = .{
            .allocator = allocator,
            .injector = options.injector,
            .net = net,
            .threads = threads,
            .handler = Context.wrap(switch (comptime @typeInfo(@TypeOf(handler))) {
                .Type => @import("router.zig").router(handler),
                .Fn => handler,
                else => @compileError("handler must be a function or a struct"),
            }),
            .keep_alive = options.keep_alive,
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

        const timeout = std.os.timeval{
            .tv_sec = @as(i32, 5),
            .tv_usec = @as(i32, 0),
        };

        std.os.setsockopt(conn.stream.handle, std.os.SOL.SOCKET, std.os.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

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
                    log.err("context: {}", .{e});
                    continue :accept;
                };

                server.handler(&ctx) catch |e| {
                    ctx.res.sendError(e) catch {};
                    continue :accept;
                };

                if (!ctx.res.responded) ctx.res.noContent() catch {};
                ctx.res.out.?.end() catch {};
            }
        }
    }
};
