const builtin = @import("builtin");
const std = @import("std");
const tk = @import("tokamak");

const App = struct {
    server: tk.Server,
    server_opts: tk.ServerOptions = .{},
    routes: []const tk.Route = &.{
        .get("/*", tk.static.dir("public", .{})),
        .get("/api/hello", hello),
    },

    fn hello() ![]const u8 {
        return "Hello, world!";
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const ct = try tk.Container.init(gpa.allocator(), &.{App});
    defer ct.deinit();

    const server = try ct.injector.get(*tk.Server);
    const port = server.http.config.port.?;

    const thread = try server.http.listenInNewThread();
    defer thread.join();

    const c = @cImport({
        @cInclude("stddef.h");
        @cInclude("webview.h");
    });

    const w = c.webview_create(if (builtin.mode == .Debug) 1 else 0, null);
    defer _ = c.webview_destroy(w);

    _ = c.webview_set_title(w, "Example");
    _ = c.webview_set_size(w, 800, 500, c.WEBVIEW_HINT_NONE);

    const url = try std.fmt.allocPrintSentinel(gpa.allocator(), "http://127.0.0.1:{}", .{port}, 0);
    defer gpa.allocator().free(url);

    _ = c.webview_navigate(w, url);
    _ = c.webview_run(w);
    server.stop();
}
