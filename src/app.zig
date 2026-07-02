const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Container = @import("container.zig").Container;
const Bundle = @import("container.zig").Bundle;
const Server = @import("server.zig").Server;

pub const ProcessInit = struct {
    init: *const std.process.Init = &current,
    args: *const std.process.Args = &current.minimal.args,
    io: *const std.Io = &current.io,

    var current: std.process.Init = undefined;
};

pub fn run(init: std.process.Init, comptime fun: anytype, comptime mods: []const type) !void {
    comptime std.debug.assert(@typeInfo(@TypeOf(fun)) == .@"fn");

    ProcessInit.current = init;
    const ct = try Container.init(init.gpa, mods ++ &[_]type{ProcessInit});
    defer ct.deinit();

    try ct.injector.call(fun);
}
