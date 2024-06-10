const std = @import("std");
const httpz = @import("httpz");
const Injector = @import("injector.zig").Injector;
const Context = @import("context.zig").Context;
const Route = @import("router.zig").Route;

pub const InitOptions = struct {
    injector: ?*const Injector = null,
};

pub const ListenOptions = struct {
    // public_url: ?[]const u8 = null,
    hostname: []const u8 = "127.0.0.1",
    port: u16,
};

/// A simple HTTP server with dependency injection.
pub const Server = struct {
    allocator: std.mem.Allocator,
    routes: []const Route,
    injector: Injector,
    http: httpz.ServerCtx(Adapter, Adapter),

    /// Initialize a new server.
    pub fn init(allocator: std.mem.Allocator, routes: []const Route, options: InitOptions) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        const http = try httpz.ServerCtx(Adapter, Adapter).init(allocator, .{}, .{ .server = self });
        errdefer http.deinit();

        self.* = .{
            .allocator = allocator,
            .routes = routes,
            .injector = Injector.init(self, options.injector),
            .http = http,
        };

        return self;
    }

    /// Deinitialize the server.
    pub fn deinit(self: *Server) void {
        self.http.deinit();
        self.allocator.destroy(self);
    }

    /// Start listening for incoming connections.
    pub fn listen(self: *Server, options: ListenOptions) !void {
        self.http.config.address = options.hostname;
        self.http.config.port = options.port;

        try self.http.listen();
    }
};

const Adapter = struct {
    server: *Server,

    pub fn handle(self: Adapter, req: *httpz.Request, res: *httpz.Response) void {
        var ctx: Context = undefined;
        ctx = .{
            .server = self.server,
            .allocator = res.arena,
            .req = req,
            .res = res,
            .current = .{ .children = self.server.routes },
            .params = .{},
            .injector = Injector.init(&ctx, &self.server.injector),
        };

        ctx.recur() catch |e| {
            ctx.send(e) catch {};
            return;
        };

        if (!ctx.responded) {
            ctx.res.status = 404;
            ctx.send(error.NotFound) catch {};
        }
    }
};
