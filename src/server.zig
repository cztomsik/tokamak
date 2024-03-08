const std = @import("std");
const log = std.log.scoped(.server);
const Injector = @import("injector.zig").Injector;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Options = struct {
    injector: Injector = Injector.empty(),
    hostname: []const u8 = "127.0.0.1",
    port: u16,
    n_threads: usize = 8,
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    allocator: std.mem.Allocator,
    injector: Injector,
    net: std.net.Server,
    threads: []std.Thread,
    stopping: std.Thread.ResetEvent = .{},
    stopped: std.Thread.ResetEvent = .{},
    handler: *const fn (*ThreadContext) anyerror!void,

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
            .handler = trampoline(switch (comptime @typeInfo(@TypeOf(handler))) {
                .Type => @import("router.zig").router(handler),
                .Fn => handler,
                else => @compileError("handler must be a function or a struct"),
            }),
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
        defer self.stopped.set();

        for (self.threads) |_| (std.net.tcpConnectToAddress(self.net.listen_address) catch continue).close();
        for (self.threads) |t| t.join();

        self.net.deinit();
        self.allocator.destroy(self);
    }

    fn loop(self: *Server) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        accept: while (!self.stopping.isSet()) {
            const conn = try self.net.accept();
            defer conn.stream.close();

            var buf: [10 * 1024]u8 = undefined;
            var http = std.http.Server.init(conn, &buf);

            while (http.state == .ready) {
                _ = arena.reset(.{ .retain_with_limit = 8 * 1024 * 1024 });

                var req = try Request.init(arena.allocator(), http.receiveHead() catch |e| {
                    if (e != error.HttpConnectionClosing) log.err("receiveHead: {}", .{e});
                    continue :accept;
                });
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
        }
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
