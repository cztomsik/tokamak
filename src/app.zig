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
    var base_allocator, const is_debug = switch (@import("builtin").mode) {
        .Debug => .{ std.heap.DebugAllocator(.{}).init, true },
        else => .{ std.heap.ArenaAllocator.init(std.heap.page_allocator), false },
    };
    defer if (is_debug) {
        const leaked = base_allocator.deinit();
        if (leaked == .leak) std.log.debug("Memory leak is detected", .{});
    } else {
        base_allocator.deinit();
    };

    try runAlloc(base_allocator.allocator(), mods);
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
