const std = @import("std");
const tk = @import("tokamak");

const api = struct {
    pub fn @"GET /"() []const u8 {
        return "Hello";
    }

    pub fn @"GET /:name"(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Hello {s}", .{name});
    }
};

const routes = &.{
    tk.logger(.{}, &.{
        tk.get("/", tk.send("Hello index")),
        tk.group("/api", &.{
            tk.router(api),
        }),
    }),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try tk.Server.init(gpa.allocator(), routes, .{});
    defer server.deinit();

    try server.listen(.{ .port = 8080 });
}
