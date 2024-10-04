const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Module = @import("module.zig").Module;
const Server = @import("server.zig").Server;
const ServerOptions = @import("server.zig").InitOptions;

pub fn run(comptime App: type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var mod = Module(App).with(&.{ &gpa.allocator(), &ServerOptions{} });
    try mod.init();
    defer mod.deinit();

    if (mod.injector.find(*Server)) |server| {
        server.injector = mod.injector;
        try server.start();
    }
}
