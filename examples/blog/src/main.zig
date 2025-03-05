const std = @import("std");
const tk = @import("tokamak");
const model = @import("model.zig");
const api = @import("api.zig");

const App = struct {
    blog_service: model.BlogService,
    server: tk.Server,
    routes: []const tk.Route = &.{
        tk.logger(.{}, &.{
            tk.static.dir("public", .{}),
            .group("/api", &.{.router(api)}),
            .get("/openapi.json", tk.swagger.json(.{ .info = .{ .title = "Example" } })),
            .get("/swagger-ui", tk.swagger.ui(.{ .url = "openapi.json" })),
        }),
    },
};

pub fn main() !void {
    try tk.app.run(App);
}
