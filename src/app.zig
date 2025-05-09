const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Container = @import("container.zig").Container;
const Server = @import("server.zig").Server;
const ServerOptions = @import("server.zig").InitOptions;

pub const Base = struct {
    pub fn initServer(ct: *Container, routes: []const @import("route.zig").Route, options: ?ServerOptions) !Server {
        var opts: ServerOptions = options orelse .{};
        opts.injector = &ct.injector;

        return .init(ct.allocator, routes, opts);
    }
};

pub fn run(comptime mods: []const type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try runAlloc(gpa.allocator(), mods);
}

pub fn runAlloc(allocator: std.mem.Allocator, comptime mods: []const type) !void {
    const ct = try Container.init(allocator, mods ++ &[_]type{Base});
    defer ct.deinit();

    // Every module can define app init/deinit hooks
    inline for (mods) |M| {
        if (std.meta.hasFn(M, "afterAppInit")) {
            try ct.injector.call(M.afterAppInit, .{});
        }

        if (std.meta.hasFn(M, "beforeAppDeinit")) {
            try ct.registerDeinit(M.beforeAppDeinit);
        }
    }

    // TODO: I am not very happy about this
    if (ct.injector.find(*Server)) |server| {
        try server.start();
    }
}
