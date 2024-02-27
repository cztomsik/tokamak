const std = @import("std");
const log = std.log.scoped(.server);
const Injector = @import("injector.zig").Injector;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Options = struct {
    injector: Injector = Injector.empty(),
    hostname: []const u8 = "127.0.0.1",
    port: u16,
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    allocator: std.mem.Allocator,
    injector: Injector,
    net: std.net.Server,
    thread: std.Thread,
    status: std.atomic.Value(enum(u8) { starting, started, stopping, stopped }) = .{ .raw = .starting },
    handler: *const fn (*ThreadContext) anyerror!void,

    /// Start a new server.
    pub fn start(allocator: std.mem.Allocator, handler: anytype, options: Options) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        const address = try std.net.Address.parseIp(options.hostname, options.port);

        var net = try address.listen(.{ .reuse_address = true });
        errdefer net.deinit();

        self.* = .{
            .allocator = allocator,
            .injector = options.injector,
            .net = net,
            .thread = try std.Thread.spawn(.{}, run, .{self}),
            .handler = trampoline(switch (comptime @typeInfo(@TypeOf(handler))) {
                .Type => @import("router.zig").router(handler),
                .Fn => handler,
                else => @compileError("handler must be a function or a struct"),
            }),
        };

        return self;
    }

    /// Stop and deinitialize the server.
    pub fn deinit(self: *Server) void {
        self.status.store(.stopping, .Release);

        if (std.net.tcpConnectToAddress(self.net.listen_address)) |conn| {
            conn.close();
        } else |e| log.err("stop err: {}", .{e});

        while (self.status.load(.Acquire) == .stopping) {
            std.time.sleep(100_000_000);
        }

        self.net.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *Server) !void {
        self.status.store(.started, .Release);
        defer self.status.store(.stopped, .Release);

        while (self.status.load(.Acquire) == .started) {
            const conn = try self.net.accept();
            errdefer conn.stream.close();

            // Sent from Server.deinit() to awake the thread
            if (self.status.load(.Acquire) == .stopping) return conn.stream.close();

            // TODO: thread pool
            var thread = try std.Thread.spawn(.{}, handle, .{ self, conn });
            thread.detach();
        }
    }

    fn handle(self: *Server, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var buf: [1024]u8 = undefined;
        var http = std.http.Server.init(conn, &buf);
        var req = try Request.init(arena.allocator(), try http.receiveHead());
        var res = Response.init(&req);

        var ctx = ThreadContext{
            .allocator = req.allocator,
            .server = self,
            .req = &req,
            .res = &res,
        };

        defer {
            if (!res.responded) res.noContent() catch {};
            res.out.?.end() catch {};
            log.debug("{s} {s} {}", .{ @tagName(req.method), req.raw.head.target, @intFromEnum(res.status) });
        }

        try self.handler(&ctx);
    }
};

const ThreadContext = struct {
    allocator: std.mem.Allocator,
    server: *Server,
    req: *Request,
    res: *Response,
};

fn trampoline(handler: anytype) fn (*ThreadContext) anyerror!void {
    const H = struct {
        fn runInThread(ctx: *ThreadContext) !void {
            const injector = Injector.multi(&.{ Injector.from(ctx), ctx.server.injector });

            ctx.res.send(injector.call(handler, .{})) catch |e| {
                log.debug("handleRequest: {}", .{e});
                ctx.res.sendError(e) catch {};
            };
        }
    };
    return H.runInThread;
}
