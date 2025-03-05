const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Module = @import("module.zig").Module;
const Server = @import("server.zig").Server;
const ServerOptions = @import("server.zig").InitOptions;

pub fn run(comptime App: type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const root = Injector.init(&.{
        &gpa.allocator(),
        &ServerOptions{},
    }, null);

    var app: App = undefined;
    const injector = try Module.initAlone(&app, &root);
    defer Module.deinit(&app);

    if (injector.find(*Server)) |server| {
        server.injector = injector;
        try server.start();
    }
}
