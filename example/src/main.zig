const std = @import("std");
const tk = @import("tokamak");
const api = @import("api.zig");

const routes = &.{
    tk.logger(.{}, &.{
        tk.static.dir("public", .{}),
        .group("/api", &.{
            .router(api),
        }),
        .get("/openapi.json", tk.swagger.json(.{ .info = .{ .title = "Example" } })),
        .get("/swagger-ui", tk.swagger.ui(.{ .url = "openapi.json" })),
    }),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var store = api.Store.init(gpa.allocator());
    defer store.deinit();

    try store.put(1, .{ .id = 1, .title = "Hello, World!", .body = "This is a test post." });
    try store.put(2, .{ .id = 2, .title = "Goodbye, World!", .body = "This is another test post." });

    var server = try tk.Server.init(gpa.allocator(), routes, .{
        .injector = tk.Injector.init(&.{&store}, null),
    });
    defer server.deinit();

    try server.listen(.{ .port = 8080 });
}
