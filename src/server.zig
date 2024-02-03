const std = @import("std");
const log = std.log.scoped(.server);
const Injector = @import("injector.zig").Injector;
const Responder = @import("responder.zig").Responder;

pub const Options = struct {
    injector: Injector = Injector.empty(),
    hostname: []const u8 = "127.0.0.1",
    port: u16,
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    allocator: std.mem.Allocator,
    injector: Injector,
    http: std.http.Server,
    thread: std.Thread,
    status: std.atomic.Value(enum(u8) { starting, started, stopping, stopped }) = .{ .raw = .starting },
    handler: *const fn (*ThreadContext) anyerror!void,

    /// Start a new server.
    pub fn start(allocator: std.mem.Allocator, handler: anytype, options: Options) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        var http = std.http.Server.init(.{ .reuse_address = true });
        errdefer http.deinit();

        const address = try std.net.Address.parseIp(options.hostname, options.port);
        try http.listen(address);

        self.* = .{
            .allocator = allocator,
            .injector = options.injector,
            .http = http,
            .thread = try std.Thread.spawn(.{}, run, .{self}),
            .handler = trampoline(switch (comptime @typeInfo(@TypeOf(handler))) {
                .Struct => @import("router.zig").router(handler),
                .Fn => handler,
                else => @compileError("handler must be a function or a struct"),
            }),
        };

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.status.store(.stopping, .Release);

        if (std.net.tcpConnectToAddress(self.http.socket.listen_address)) |conn| {
            conn.close();
        } else |e| log.err("stop err: {}", .{e});

        while (self.status.load(.Acquire) == .stopping) {
            std.time.sleep(100_000_000);
        }

        self.http.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *Server) !void {
        self.status.store(.started, .Release);
        defer self.status.store(.stopped, .Release);

        while (self.status.load(.Acquire) == .started) {
            // TODO: thread pool
            const ctx = try ThreadContext.init(self);

            try ctx.accept();

            // Sent from Server.deinit() to awake the thread
            if (self.status.load(.Acquire) == .stopping) return;

            var thread = try std.Thread.spawn(.{}, ThreadContext.callHandler, .{ctx});
            thread.detach();
        }
    }
};

const ThreadContext = struct {
    server: *Server,
    arena: std.heap.ArenaAllocator,
    res: std.http.Server.Response = undefined,
    responder: Responder = undefined,

    fn init(server: *Server) !*ThreadContext {
        const self = try server.allocator.create(ThreadContext);
        errdefer server.allocator.destroy(self);

        self.* = .{
            .server = server,
            .arena = std.heap.ArenaAllocator.init(server.allocator),
        };

        return self;
    }

    fn accept(self: *ThreadContext) !void {
        self.res = try self.server.http.accept(.{
            .allocator = self.arena.allocator(),
            .header_strategy = .{ .dynamic = 10_000 },
        });

        self.responder = .{
            .res = &self.res,
        };
    }

    fn callHandler(self: *ThreadContext) !void {
        defer self.deinit();

        // Keep it simple
        try self.res.headers.append("Connection", "close");

        // Wait for the request to be fully read
        try self.res.wait();

        defer {
            if (self.res.state == .waited) self.res.send() catch {};
            self.res.finish() catch {};
            log.debug("{s} {s} {}", .{ @tagName(self.res.request.method), self.res.request.target, @intFromEnum(self.res.status) });
        }

        try self.server.handler(self);
    }

    fn deinit(self: *ThreadContext) void {
        _ = self.res.reset();
        self.res.deinit();

        self.arena.deinit();
        self.arena.child_allocator.destroy(self);
    }
};

fn trampoline(handler: anytype) fn (*ThreadContext) anyerror!void {
    const H = struct {
        fn runInThread(ctx: *ThreadContext) !void {
            var scope = .{
                .allocator = ctx.arena.allocator(),
                .responder = &ctx.responder,
                .req = &ctx.res.request,
                .res = &ctx.res,
                .uri = try std.Uri.parseWithoutScheme(ctx.res.request.target),
            };

            const injector = Injector.multi(&.{ Injector.from(&scope), ctx.server.injector });

            ctx.responder.send(injector.call(handler, .{})) catch |e| {
                log.debug("handleRequest: {}", .{e});
                ctx.responder.sendError(e) catch {};
            };
        }
    };
    return H.runInThread;
}
