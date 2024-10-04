const std = @import("std");
const tk = @import("tokamak");

const App = struct {
    server: *tk.Server,
    routes: []const tk.Route = &.{
        .get("/", hello),
    },

    fn hello() ![]const u8 {
        return "Hello, world!";
    }
};

pub fn main() !void {
    try tk.app.run(App);
}
