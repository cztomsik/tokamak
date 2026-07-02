const std = @import("std");
const httpz = @import("httpz");
const Injector = @import("injector.zig").Injector;
const How = @import("container.zig").How;
const Context = @import("context.zig").Context;
const Route = @import("route.zig").Route;

/// Configuration for `Server.init()`. Most options are passed through to httpz.
pub const InitOptions = struct {
    listen: ListenOptions = .{},
    /// Parent injector for dependency resolution. Set automatically by `tk.app.run()`.
    injector: ?*Injector = null,
    workers: httpz.Config.Worker = .{},
    request: httpz.Config.Request = .{},
    response: httpz.Config.Response = .{},
    timeout: httpz.Config.Timeout = .{},
    thread_pool: httpz.Config.ThreadPool = .{},
    websocket: httpz.Config.Websocket = .{},
};

/// Address and port to listen on.
pub const ListenOptions = struct {
    hostname: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    gpa: std.mem.Allocator,
    routes: []const Route,
    injector: ?*Injector,
    http: httpz.Server(Adapter),

    pub const provider: How = .factory(initWithinApp);

    /// Initialize a new server.
    pub fn init(io: std.Io, gpa: std.mem.Allocator, routes: []const Route, options: InitOptions) !Server {
        const http = try httpz.Server(Adapter).init(io, gpa, .{
            .address = .{ .ip = .{ .ip4 = try .parse(options.listen.hostname, options.listen.port) } },
            .workers = options.workers,
            .request = options.request,
            .response = options.response,
            .timeout = options.timeout,
            .thread_pool = options.thread_pool,
            .websocket = options.websocket,
        }, .{});
        errdefer http.deinit();

        return .{
            .gpa = gpa,
            .routes = routes,
            .injector = options.injector,
            .http = http,
        };
    }

    pub fn initWithinApp(io: std.Io, gpa: std.mem.Allocator, routes: []const Route, inj: *Injector) !Server {
        var opts: InitOptions = inj.find(InitOptions) orelse .{};
        opts.injector = inj;

        return init(io, gpa, routes, opts);
    }

    /// Deinitialize the server.
    pub fn deinit(self: *Server) void {
        self.http.deinit();
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
        const http: *httpz.Server(Adapter) = @alignCast(@fieldParentPtr("handler", self));
        const server: *Server = @alignCast(@fieldParentPtr("http", http));

        var ctx: Context = undefined;

        var inj: Injector = .init(&.{
            .ref(&ctx),
            .ref(server),
            .ref(&server.http.io),
            .ref(&req.arena),
            .ref(req),
            .ref(res),
        }, server.injector);

        ctx = .{
            .server = server,
            .allocator = res.arena,
            .req = req,
            .res = res,
            .current = .{ .children = server.routes },
            .params = .{},
            .injector = &inj,
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
