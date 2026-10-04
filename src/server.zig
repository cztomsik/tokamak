const std = @import("std");
const dusty = @import("dusty");
const Injector = @import("injector.zig").Injector;
const Provider = @import("container.zig").Provider;
const Context = @import("context.zig").Context;
const Route = @import("route.zig").Route;

/// Configuration for `Server.init()`.
pub const InitOptions = struct {
    listen: ListenOptions = .{},
    /// Parent injector for dependency resolution. Set automatically by `tk.app.run()`.
    injector: ?*Injector = null,
    request: dusty.ServerConfig.Request = .{},
    timeout: dusty.ServerConfig.Timeout = .{},
    max_connections: ?u32 = 10_000,
    trusted_proxy_hops: usize = 0,
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
    http: dusty.Server(Adapter),
    listener: dusty.Listener,
    adapter: Adapter = undefined,
    running: ?std.Io.Future(@typeInfo(@TypeOf(start)).@"fn".return_type.?) = null,

    pub const provider: Provider = .factory(initWithinApp);

    /// Initialize a new server.
    pub fn init(io: std.Io, gpa: std.mem.Allocator, routes: []const Route, options: InitOptions) !Server {
        const listener: dusty.Listener = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse(options.listen.hostname, options.listen.port) },
        };
        return .{
            .gpa = gpa,
            .routes = routes,
            .injector = options.injector,
            .http = dusty.Server(Adapter).init(gpa, io, .{
                .request = options.request,
                .timeout = options.timeout,
                .max_connections = options.max_connections,
                .trusted_proxy_hops = options.trusted_proxy_hops,
            }, undefined),
            .listener = listener,
        };
    }

    pub fn initWithinApp(io: std.Io, gpa: std.mem.Allocator, routes: []const Route, inj: *Injector) !Server {
        var opts: InitOptions = inj.find(InitOptions) orelse .{};
        opts.injector = inj;

        return init(io, gpa, routes, opts);
    }

    /// Deinitialize the server.
    pub fn deinit(self: *Server) void {
        self.stop();
        self.http.deinit();
    }

    /// Start listening for incoming connections.
    pub fn start(self: *Server) !void {
        self.adapter = .{ .server = self };
        self.http.ctx = &self.adapter;
        self.http.config.listen = &.{self.listener};
        self.http.router.any("/", Adapter.handle);
        self.http.router.any("/*", Adapter.handle);
        return self.http.run();
    }

    /// Start listening in a concurrent task and wait until the socket is ready.
    pub fn startInBackground(self: *Server) !void {
        self.running = try self.http.io.concurrent(Server.start, .{self});
        errdefer self.stop();
        try self.http.ready.wait(self.http.io);
    }

    /// Stop the server.
    pub fn stop(self: *Server) void {
        if (self.running) |*future| {
            _ = future.cancel(self.http.io) catch |err| if (err != error.Canceled) {
                std.log.err("Server stopped: {}", .{err});
            };
            self.running = null;
        }
    }
};

const Adapter = struct {
    server: *Server,

    pub fn handle(self: *Adapter, req: *dusty.Request, res: *dusty.Response) anyerror!void {
        const server = self.server;

        if (std.mem.indexOfScalar(u8, req.url, '?')) |index| {
            var pairs = std.mem.splitScalar(u8, req.url[index + 1 ..], '&');
            while (pairs.next()) |pair| {
                if (pair.len == 0) continue;
                if (req.query.count() >= req.config.max_query_count) return error.TooManyQueryParams;
                const separator = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
                const key = try dusty.Request.urlUnescape(req.arena, pair[0..separator]);
                const value = if (separator < pair.len) try dusty.Request.urlUnescape(req.arena, pair[separator + 1 ..]) else "";
                try req.query.map.put(req.arena, key, value);
            }
        }

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
            ctx.res.status = .not_found;
            ctx.send(error.NotFound) catch {};
        }
    }
};
