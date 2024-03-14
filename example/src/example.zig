const std = @import("std");
const tk = @import("tokamak");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try tk.Server.start(gpa.allocator(), handler, .{ .port = 8080 });
    server.wait();
}

const handler = tk.chain(.{
    tk.logger(.{}),
    tk.get("/", tk.send("Hello")),
    tk.group("/api", tk.router(api)),
    tk.send(error.NotFound),
});

const api = struct {
    pub fn @"GET /"() []const u8 {
        return "Hello";
    }

    pub fn @"GET /:name"(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Hello {s}", .{name});
    }
};
