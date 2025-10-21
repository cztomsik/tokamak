const std = @import("std");
const tk = @import("tokamak");
const model = @import("model.zig");
const api = @import("api.zig");

// Shared services that BlogService depends on
const ServicesModule = struct {
    cache: model.Cache,
    validator: model.Validator,
};

const App = struct {
    blog_service: model.BlogService,
    server: tk.Server,
    routes: []const tk.Route = &.{
        tk.logger(.{}, &.{
            tk.static.dir("public", .{}),
            .group("/api", &.{.router(api)}),
            .get("/openapi.json", tk.swagger.json(.{ .info = .{ .title = "Blog API" } })),
            .get("/swagger-ui", tk.swagger.ui(.{ .url = "openapi.json" })),
        }),
    },

    pub fn configure(bundle: *tk.Bundle) void {
        // Add init hook to print server info
        bundle.addInitHook(printServerInfo);
    }

    fn printServerInfo(server: *tk.Server) void {
        std.debug.print("Blog API started on http://localhost:{d}\n", .{
            server.http.config.port.?,
        });
        std.debug.print("Swagger UI: http://localhost:{d}/swagger-ui\n", .{
            server.http.config.port.?,
        });
    }
};

pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{ ServicesModule, App });
}
