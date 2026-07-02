const builtin = @import("builtin");
const c = @import("c");
const std = @import("std");
const tk = @import("tokamak");

const App = struct {
    server: tk.Server,
    server_opts: tk.ServerOptions = .{},
    routes: []const tk.Route = &.{
        .get("/*", tk.static.dir("public", .{})),
        .get("/api/hello", hello),
        .get("/api/sse", sse),
    },

    fn hello() ![]const u8 {
        return "Hello, world!";
    }

    fn sse(io: std.Io) tk.EventStream(Ticker) {
        return .{ .impl = .{ .io = io } };
    }
};

const Ticker = struct {
    io: std.Io,
    count: u64 = 0,

    pub fn next(self: *Ticker) !?u64 {
        try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
        self.count += 1;
        return self.count;
    }
};

pub fn main(init: std.process.Init) !void {
    try tk.app.run(init, webviewMain, &.{App});
}

pub fn webviewMain(server: *tk.Server, gpa: std.mem.Allocator) !void {
    const address = server.http.config.address;

    const thread = try server.http.listenInNewThread();
    defer thread.join();

    const w = c.webview_create(if (builtin.mode == .Debug) 1 else 0, null);
    defer _ = c.webview_destroy(w);

    _ = c.webview_set_title(w, "Example");
    _ = c.webview_set_size(w, 800, 500, c.WEBVIEW_HINT_NONE);

    const url = try std.fmt.allocPrintSentinel(gpa, "http://{f}", .{address}, 0);
    defer gpa.free(url);

    _ = c.webview_navigate(w, url);
    _ = c.webview_run(w);
    server.stop();
}
