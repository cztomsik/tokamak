const std = @import("std");
const tk = @import("tokamak");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try tk.Server.start(gpa.allocator(), example, .{ .port = 8080 });
    server.thread.join();
}

// fn example() []const u8 {
//     return "Hello";
// }

// fn example(allocator: std.mem.Allocator) ![]const u8 {
//     return std.fmt.allocPrint(allocator, "Hello {}", .{std.time.timestamp()});
// }

fn example(injector: tk.Injector, req: *tk.Request, res: *tk.Response) !void {
    // Here we could do authentication, logging, etc.
    std.log.debug("{}", .{req.url});

    return res.send(injector.call(tk.router(api), .{}));
}

const api = struct {
    pub fn @"GET /"() []const u8 {
        return "Hello";
    }

    pub fn @"GET /:name"(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Hello {s}", .{name});
    }
};
