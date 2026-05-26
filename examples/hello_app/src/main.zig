const std = @import("std");
const tk = @import("tokamak");

const App = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{
        .get("/", hello),
    },

    fn hello() ![]const u8 {
        return "Hello, world!";
    }
};

pub fn main(init: std.process.Init) !void {
    try tk.app.run(init, tk.Server.start, &.{App});
}
