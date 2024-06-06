const std = @import("std");
const xev = @import("xev");
const Injector = @import("injector.zig").Injector;
const Route = @import("router.zig").Route;
const Request = @import("request.zig").Request;
const Params = @import("request.zig").Params;
const Response = @import("response.zig").Response;

const log = std.log.scoped(.server);
const Fd = if (xev.backend == .iocp) std.os.windows.HANDLE else std.posix.socket_t;

pub const InitOptions = struct {
    injector: ?*const Injector = null,
    thread_pool: xev.ThreadPool.Config = .{
        // TODO: could be smaller, but 1M causes cryptic messages like "panicked during panic"
        .stack_size = 16 * 1024 * 1024,
    },
};

pub const ListenOptions = struct {
    // public_url: ?[]const u8 = null,
    hostname: []const u8 = "127.0.0.1",
    port: u16,
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

    fn init(allocator: std.mem.Allocator, server: *Server, head: []const u8) !*Context {
        const self = try allocator.create(Context);

        self.* = .{
            .server = server,
            .allocator = allocator,
            .req = try Request.init(allocator, head),
            .res = .{ .headers = std.ArrayList(std.http.Header).init(allocator) },
            .current = .{ .children = server.routes },
            .params = .{},
            .injector = Injector.init(self, &server.injector),
        };

        self.res.keep_alive = self.req.head.keep_alive;

        return self;
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

            if (self.res.status != null) return;
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
    loop: Loop,
    acceptor: ?Acceptor = null,
    thread_pool: xev.ThreadPool,
    injector: Injector,

    pub fn init(allocator: std.mem.Allocator, routes: []const Route, options: InitOptions) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        const loop = try Loop.init();
        errdefer loop.deinit();

        const thread_pool = xev.ThreadPool.init(options.thread_pool);
        errdefer thread_pool.deinit();

        self.* = .{
            .allocator = allocator,
            .routes = routes,
            .loop = loop,
            .thread_pool = thread_pool,
            .injector = Injector.init(self, options.injector),
        };

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.thread_pool.deinit();
        self.loop.deinit();
        self.allocator.destroy(self);
    }

    pub fn listen(self: *Server, options: ListenOptions) !void {
        if (self.acceptor != null) {
            return error.AlreadyListening;
        }

        const addr = try std.net.Address.parseIp4(options.hostname, options.port);
        var socket = try xev.TCP.init(addr);

        try socket.bind(addr);
        try socket.listen(std.os.linux.SOMAXCONN);

        self.acceptor = .{ .server = self, .fd = socket.fd };
        self.loop.accept(&self.acceptor.?, Acceptor.accept);

        try self.loop.run();
    }
};

const Acceptor = struct {
    server: *Server,
    fd: Fd,
    comp: xev.Completion = .{},

    fn accept(self: *Acceptor, res: xev.AcceptError!Fd) void {
        const sock = res catch @panic("TODO");
        const conn = self.server.allocator.create(Connection) catch @panic("TODO");

        conn.* = .{
            .server = self.server,
            .arena = std.heap.ArenaAllocator.init(self.server.allocator),
            .fd = sock,
        };

        self.server.loop.read(conn, &conn.buf, Connection.parseHead);
        self.server.loop.accept(self, accept);
    }
};

const Connection = struct {
    server: *Server,
    arena: std.heap.ArenaAllocator,
    fd: Fd,
    buf: [8 * 1024]u8 = undefined,

    input: []const u8 = &.{},
    res: ?*Response = null,

    comp: xev.Completion = .{},
    task: xev.ThreadPool.Task = .{ .callback = handle },
    done: ?xev.Async = null,

    fn fail(self: *Connection, err: anyerror) void {
        switch (err) {
            error.EOF, error.ConnectionResetByPeer => {},
            else => log.err("err: {}", .{err}),
        }

        self.close();
    }

    fn parseHead(self: *Connection, res: xev.ReadError!usize) void {
        self.input = self.buf[0 .. res catch |e| return self.fail(e)];
        self.done = self.done orelse xev.Async.init() catch |e| return self.fail(e);

        self.server.thread_pool.schedule(xev.ThreadPool.Batch.from(&self.task));

        self.done.?.wait(&self.server.loop.inner, &self.comp, Connection, self, (struct {
            fn callback(conn: ?*Connection, _: *xev.Loop, _: *xev.Completion, _: xev.Async.WaitError!void) xev.CallbackAction {
                conn.?.sendHead();
                return .disarm;
            }
        }).callback);
    }

    fn handle(task: *xev.ThreadPool.Task) void {
        const self: *Connection = @fieldParentPtr("task", task);
        defer self.done.?.notify() catch {};

        if (std.mem.indexOf(u8, self.input, "\r\n\r\n")) |i| {
            const ctx = Context.init(self.arena.allocator(), self.server, self.input[0 .. i + 4]) catch |e| {
                std.log.err("err: {}", .{e});
                return;
            };

            ctx.recur() catch |e| {
                ctx.res.sendError(e) catch {};
            };

            if (ctx.res.status == null) {
                ctx.res.sendError(error.NotFound) catch {};
            }

            self.res = &ctx.res;
        } else {
            @panic("TODO");
        }
    }

    fn sendHead(self: *Connection) void {
        const res = self.res orelse {
            log.debug("invalid req {s}", .{self.input});
            return self.close();
        };

        var fbs = std.io.fixedBufferStream(&self.buf);
        res.writeHead(fbs.writer()) catch |e| return self.fail(e);

        self.server.loop.write(self, fbs.getWritten(), sendBody);
    }

    fn sendBody(self: *Connection, res: xev.WriteError!usize) void {
        _ = res catch |e| return self.fail(e);

        self.server.loop.write(self, self.res.?.body.slice, finish);
    }

    fn finish(self: *Connection, res: xev.WriteError!usize) void {
        _ = res catch |e| return self.fail(e);

        if (self.res.?.keep_alive) {
            self.reset();
        } else {
            self.close();
        }
    }

    fn reset(self: *Connection) void {
        _ = self.arena.reset(.{ .retain_with_limit = 8 * 1024 });
        self.input = &.{};
        self.res = null;

        self.server.loop.read(self, &self.buf, parseHead);
    }

    fn close(self: *Connection) void {
        self.server.loop.close(self, deinit);
    }

    fn deinit(self: *Connection, _: xev.CloseError!void) void {
        if (self.done) |*d| d.deinit();
        self.arena.deinit();
        self.server.allocator.destroy(self);
    }
};

// QoL wrapper
const Loop = struct {
    inner: xev.Loop,
    // TODO: WriteQueue? so we can always write() in order?

    const Operation = std.meta.FieldType(xev.Completion, .op);

    fn init() !Loop {
        return .{
            .inner = try xev.Loop.init(.{}),
        };
    }

    fn deinit(self: *Loop) void {
        self.inner.deinit();
    }

    fn run(self: *Loop) !void {
        return self.inner.run(.until_done);
    }

    fn accept(self: *Loop, cx: anytype, comptime fun: XevCb(@TypeOf(cx), .accept)) void {
        self.add(.accept, .{ .socket = cx.fd }, cx, fun);
    }

    fn read(self: *Loop, cx: anytype, buf: []u8, comptime fun: XevCb(@TypeOf(cx), .read)) void {
        self.add(.recv, .{ .fd = cx.fd, .buffer = .{ .slice = buf } }, cx, fun);
    }

    fn write(self: *Loop, cx: anytype, buf: []const u8, comptime fun: XevCb(@TypeOf(cx), .write)) void {
        self.add(.send, .{ .fd = cx.fd, .buffer = .{ .slice = buf } }, cx, fun);
    }

    fn shutdown(self: *Loop, cx: anytype, comptime fun: XevCb(@TypeOf(cx), .shutdown)) void {
        self.add(.shutdown, .{ .socket = cx.fd, .how = .send }, cx, fun);
    }

    fn close(self: *Loop, cx: anytype, comptime fun: XevCb(@TypeOf(cx), .close)) void {
        self.add(.close, .{ .fd = cx.fd }, cx, fun);
    }

    fn add(self: *Loop, comptime kind: std.meta.Tag(Operation), payload: std.meta.FieldType(Operation, kind), ptr: anytype, comptime fun: anytype) void {
        const H = struct {
            fn callback(ptr2: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, res: xev.Result) xev.CallbackAction {
                if (fun) |f| f(@alignCast(@ptrCast(ptr2.?)), @field(res, @tagName(kind)));
                return .disarm;
            }
        };

        ptr.comp = .{
            .op = @unionInit(Operation, @tagName(kind), payload),
            .userdata = @ptrCast(ptr),
            .callback = &H.callback,
        };

        self.inner.add(&ptr.comp);
    }
};

fn XevCb(comptime P: type, kind: std.meta.FieldEnum(xev.Result)) type {
    return ?fn (P, std.meta.FieldType(xev.Result, kind)) void;
}
