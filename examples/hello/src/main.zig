const std = @import("std");
const tk = @import("tokamak");

const routes: []const tk.Route = &.{
    .get("/", hello),
};

fn hello() ![]const u8 {
    return "Hello, world!";
}

pub fn main(init: std.process.Init) !void {
    var server = try tk.Server.init(init.io, init.gpa, routes, .{});
    defer server.deinit();

    try server.start();
}
