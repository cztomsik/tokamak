const std = @import("std");
const http = @import("backend/http.zig");
const Injector = @import("injector.zig").Injector;
const Provider = @import("container.zig").Provider;
const Context = @import("context.zig").Context;
const Route = @import("route.zig").Route;
const Backend = switch (@import("backend_options").backend) {
    .dusty => @import("backend/dusty.zig").Backend,
    .httpz => @import("backend/httpz.zig").Backend,
};

pub const InitOptions = struct {
    listen: ListenOptions = .{},
    injector: ?*Injector = null,
    request: RequestOptions = .{},
    timeout: TimeoutOptions = .{},
    max_connections: ?u32 = 10_000,
    trusted_proxy_hops: usize = 0,
};

pub const RequestOptions = struct {
    max_body_size: usize = 1_048_576,
    max_query_count: usize = 32,
};

pub const TimeoutOptions = struct {
    request: ?std.Io.Duration = .fromSeconds(30),
    keepalive: ?std.Io.Duration = .fromSeconds(60),
};

pub const ListenOptions = struct {
    hostname: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    routes: []const Route,
    injector: ?*Injector,
    options: InitOptions,
    backend: *Backend,
    initialized: bool = false,

    pub const provider: Provider = .factory(initWithinApp);

    pub fn init(io: std.Io, gpa: std.mem.Allocator, routes: []const Route, options: InitOptions) !Server {
        _ = try std.Io.net.IpAddress.parse(options.listen.hostname, options.listen.port);
        const backend = try gpa.create(Backend);
        return .{
            .io = io,
            .gpa = gpa,
            .routes = routes,
            .injector = options.injector,
            .options = options,
            .backend = backend,
        };
    }

    pub fn initWithinApp(io: std.Io, gpa: std.mem.Allocator, routes: []const Route, inj: *Injector) !Server {
        var opts: InitOptions = inj.find(InitOptions) orelse .{};
        opts.injector = inj;
        return init(io, gpa, routes, opts);
    }

    fn prepare(self: *Server) !void {
        if (self.initialized) return error.AlreadyRunning;
        self.backend.* = try Backend.init(self);
        self.initialized = true;
    }

    pub fn deinit(self: *Server) void {
        if (self.initialized) self.backend.deinit();
        self.gpa.destroy(self.backend);
    }

    pub fn start(self: *Server) !void {
        try self.prepare();
        errdefer {
            self.backend.deinit();
            self.initialized = false;
        }
        try self.backend.start();
    }

    pub fn startInBackground(self: *Server) !void {
        try self.prepare();
        errdefer {
            self.backend.deinit();
            self.initialized = false;
        }
        try self.backend.startInBackground();
    }

    pub fn stop(self: *Server) void {
        if (self.initialized) {
            self.backend.deinit();
            self.initialized = false;
        }
    }

    pub fn port(self: *const Server) u16 {
        return if (self.initialized) self.backend.port() else self.options.listen.port;
    }

    pub fn dispatch(self: *Server, req: *http.Request, res: *http.Response) !void {
        var ctx: Context = undefined;
        var inj: Injector = .init(&.{
            .ref(&ctx),
            .ref(self),
            .ref(&self.io),
            .ref(&req.arena),
            .ref(req),
            .ref(res),
        }, self.injector);
        ctx = .{
            .server = self,
            .allocator = req.arena,
            .req = req,
            .res = res,
            .current = .{ .children = self.routes },
            .params = .{},
            .injector = &inj,
        };
        ctx.next() catch |err| {
            try ctx.send(err);
            return;
        };
        if (!ctx.responded) {
            res.status = 404;
            try ctx.send(error.NotFound);
        }
    }
};
