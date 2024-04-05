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
    chain: []const *const fn (*Context) anyerror!void = &.{},
    drained: bool = false,

    fn init(self: *Context, allocator: std.mem.Allocator, server: *Server, http: *std.http.Server) !void {
        const raw = http.receiveHead() catch |e| {
            if (e == error.HttpHeadersUnreadable) return error.HttpConnectionClosing;
            return e;
        };

        self.* = .{
            .allocator = allocator,
            .req = try Request.init(allocator, raw),
            .res = .{ .req = &self.req },
            .injector = .{ .parent = &server.injector },
        };

        self.res.keep_alive = server.keep_alive;

        try self.injector.push(&allocator);
        try self.injector.push(&self.req);
        try self.injector.push(&self.res);
        try self.injector.push(self);
    }

    /// Run a handler in a scoped context. This means `next` will only run the
    /// remaining handlers in the provided chain and the injector will be reset
    /// to its previous state after the handler has been run. If all the
    /// handlers have been run, it will return `true`, otherwise `false`.
    pub fn runScoped(self: *Context, handler: *const Handler, chain: []const *const Handler) !bool {
        const n_deps = self.injector.registry.len;
        const prev = self.chain;
        defer {
            self.injector.registry.len = n_deps;
            self.chain = prev;
            self.drained = false;
        }

        self.chain = chain;
        self.drained = false;

        try handler(self);
        return self.drained;
    }

    /// Run the next middleware or handler in the chain.
    pub inline fn next(self: *Context) !void {
        if (self.chain.len > 0) {
            const handler = self.chain[0];
            self.chain = self.chain[1..];
            return handler(self);
        } else {
            self.drained = true;
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

    /// Run the server, blocking the current thread.
    pub fn run(allocator: std.mem.Allocator, handler: anytype, options: Options) !void {
        var server = try start(allocator, handler, options);
        defer server.deinit();

        server.wait();
    }

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
                    if (!ctx.res.responded) ctx.res.noContent() catch {};
                    ctx.res.out.?.end() catch {};
                }

                server.handler(&ctx) catch |e| {
                    log.err("handler: {}", .{e});
                    ctx.res.sendError(e) catch {};
                    continue :accept;
                };
            }
        }
    }
};
