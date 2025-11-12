const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Container = @import("container.zig").Container;
const Bundle = @import("container.zig").Bundle;
const Server = @import("server.zig").Server;
const ServerOptions = @import("server.zig").InitOptions;

pub const Base = struct {
    pub fn configure(bundle: *Bundle) void {
        bundle.addCompileHook(maybeConfigureServer);
    }

    fn maybeConfigureServer(bundle: *Bundle) void {
        if (bundle.findDep(*Server)) |_| {
            // TODO: auto-provide defaults? shorthand for this pattern?
            if (bundle.findDep(ServerOptions) == null) {
                bundle.add(ServerOptions, .value(ServerOptions{}));
            }

            bundle.addInitHook(setServerInjector);
        }
    }

    // TODO: This is because *Injector is part of ServerOptions
    fn setServerInjector(server: *Server, inj: *Injector) void {
        server.injector = inj;
    }
};

pub fn run(comptime fun: anytype, comptime mods: []const type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try runAlloc(fun, gpa.allocator(), mods);
}

pub fn runAlloc(comptime fun: anytype, allocator: std.mem.Allocator, comptime mods: []const type) !void {
    comptime std.debug.assert(@typeInfo(@TypeOf(fun)) == .@"fn");

    const ct = try Container.init(allocator, mods ++ &[_]type{Base});
    defer ct.deinit();

    try ct.injector.call(fun);
}
