const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Container = @import("container.zig").Container;
const Bundle = @import("container.zig").Bundle;
const Server = @import("server.zig").Server;
const ServerOptions = @import("server.zig").InitOptions;

pub const ProcessInit = struct {
    init: *const std.process.Init = &current,
    args: *const std.process.Args = &current.minimal.args,
    io: *const std.Io = &current.io,

    var current: std.process.Init = undefined;
};

pub const Base = struct {
    pub fn configure(bundle: *Bundle) void {
        bundle.addCompileHook(maybeConfigureServer);
    }

    fn maybeConfigureServer(bundle: *Bundle) void {
        if (bundle.findDep(*Server)) |_| {
            // TODO: auto-provide defaults? shorthand for this pattern?
            if (bundle.findDep(ServerOptions) == null) {
                bundle.provide(ServerOptions, .value(ServerOptions{}));
            }

            bundle.addInitHook(setServerInjector);
        }
    }

    // TODO: This is because *Injector is part of ServerOptions
    fn setServerInjector(server: *Server, inj: *Injector) void {
        server.injector = inj;
    }
};

pub fn run(init: std.process.Init, comptime fun: anytype, comptime mods: []const type) !void {
    comptime std.debug.assert(@typeInfo(@TypeOf(fun)) == .@"fn");

    ProcessInit.current = init;
    const ct = try Container.init(init.gpa, mods ++ &[_]type{ ProcessInit, Base });
    defer ct.deinit();

    try ct.injector.call(fun);
}
