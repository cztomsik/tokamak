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
    try server.startInBackground();
    defer server.stop();
    const hostname = if (std.mem.eql(u8, server.options.listen.hostname, "0.0.0.0")) "127.0.0.1" else if (std.mem.eql(u8, server.options.listen.hostname, "::")) "::1" else server.options.listen.hostname;
    const address = try std.Io.net.IpAddress.parse(hostname, server.port());

    const w = c.webview_create(if (builtin.mode == .debug) 1 else 0, null);
    defer _ = c.webview_destroy(w);

    _ = c.webview_set_title(w, "Example");
    _ = c.webview_set_size(w, 800, 500, c.WEBVIEW_HINT_NONE);

    const url = try std.fmt.allocPrintSentinel(gpa, "http://{f}", .{address}, 0);
    defer gpa.free(url);

    _ = c.webview_navigate(w, url);
    _ = c.webview_run(w);
}
