const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Container = @import("container.zig").Container;
const Server = @import("server.zig").Server;
const ServerOptions = @import("server.zig").InitOptions;

const Base = struct {
    pub fn initServer(allocator: std.mem.Allocator, routes: []const @import("route.zig").Route, options: ?ServerOptions) !Server {
        return Server.init(allocator, routes, options orelse .{});
    }
};

pub fn run(comptime App: type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const ct = try Container.init(gpa.allocator(), &.{ App, Base });
    defer ct.deinit();

    if (ct.injector.find(*Server)) |server| {
        server.injector = ct.injector;
        try server.start();
    }
}
