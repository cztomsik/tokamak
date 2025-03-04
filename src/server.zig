const std = @import("std");
const httpz = @import("httpz");
const Injector = @import("injector.zig").Injector;
const Context = @import("context.zig").Context;
const Route = @import("route.zig").Route;

pub const InitOptions = struct {
    listen: ListenOptions = .{},
    injector: Injector = Injector.empty,
    workers: httpz.Config.Worker = .{},
    request: httpz.Config.Request = .{},
    response: httpz.Config.Response = .{},
    timeout: httpz.Config.Timeout = .{},
    thread_pool: httpz.Config.ThreadPool = .{},
    websocket: httpz.Config.Websocket = .{},
};

pub const ListenOptions = struct {
    hostname: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    allocator: std.mem.Allocator,
    routes: []const Route,
    injector: Injector,
    http: httpz.Server(Adapter),

    /// Initialize a new server.
    pub fn init(allocator: std.mem.Allocator, routes: []const Route, options: InitOptions) !Server {
        const http = try httpz.Server(Adapter).init(allocator, .{
            .address = options.listen.hostname,
            .port = options.listen.port,
            .workers = options.workers,
            .request = options.request,
            .response = options.response,
            .timeout = options.timeout,
            .thread_pool = options.thread_pool,
            .websocket = options.websocket,
        }, .{});
        errdefer http.deinit();

        return .{
            .allocator = allocator,
            .routes = routes,
            .injector = options.injector,
            .http = http,
        };
    }

    /// Deinitialize the server.
    pub fn deinit(self: *Server) void {
        self.http.deinit();
        self.allocator.destroy(self);
    }

    /// Start listening for incoming connections.
    pub fn start(self: *Server) !void {
        try self.http.listen();
    }

    /// Stop the server.
    pub fn stop(self: *Server) void {
        self.http.stop();
    }
};

const Adapter = struct {
    pub fn handle(self: *Adapter, req: *httpz.Request, res: *httpz.Response) void {
        const offset = @offsetOf(Server, "http") + @offsetOf(httpz.Server(Adapter), "handler");
        const server: *Server = @ptrFromInt(@intFromPtr(self) - offset);

        var ctx: Context = undefined;
        ctx = .{
            .server = server,
            .allocator = res.arena,
            .req = req,
            .res = res,
            .current = .{ .children = server.routes },
            .params = .{},
            .injector = Injector.init(&ctx, &server.injector),
        };

        ctx.next() catch |e| {
            ctx.send(e) catch {};
            return;
        };

        if (!ctx.responded) {
            ctx.res.status = 404;
            ctx.send(error.NotFound) catch {};
        }
    }
};
