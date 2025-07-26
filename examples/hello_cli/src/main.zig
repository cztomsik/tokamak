const std = @import("std");
const tk = @import("tokamak");

const App = struct {
    http_client: tk.http.StdClient,
    hn_client: tk.hackernews.Client,
};

const Cli = struct {
    cmds: []const tk.cli.Command = &.{
        .usage,
        .cmd0("hello", "Print a greeting message", hello),
        .cmd1("hn", "Show top Hacker News stories", show_hn),
        .cmd2("scrape", "Scrape a URL with optional CSS selector", scrape),
        .cmd3("substr", "Get substring with bounds checking", substr),
    },

    fn hello() []const u8 {
        return "Hello World!";
    }

    fn show_hn(hn_client: *tk.hackernews.Client, allocator: std.mem.Allocator, limit: ?u8) ![]const tk.hackernews.Story {
        return hn_client.getTopStories(allocator, limit orelse 10);
    }

    fn scrape(allocator: std.mem.Allocator, http_client: *tk.http.Client, url: []const u8, qs: ?[]const u8) !void {
        const res = try http_client.request(allocator, .{ .url = url });

        const doc = try tk.dom.Document.parseFromSlice(allocator, res.body);
        defer doc.deinit();

        var node = &doc.node;

        if (qs) |sel| {
            if (try doc.querySelector(sel)) |el| node = &el.node;
        }

        node.dump();
    }

    fn substr(str: []const u8, start: ?usize, end: ?usize) ![]const u8 {
        if ((start orelse 0) > str.len or (end orelse str.len) > str.len) return error.OutOfBounds;
        return str[start orelse 0 .. end orelse str.len];
    }
};

pub fn main() !void {
    std.debug.print(tk.ansi.clear, .{});

    try tk.app.run(tk.cli.run, &.{ App, Cli });
}
