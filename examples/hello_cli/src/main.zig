const std = @import("std");
const tk = @import("tokamak");

// Shared
const App = struct {
    http_client: tk.http.StdClient,
    hn_client: tk.hackernews.Client,
};

// CLI-only
const Cli = struct {
    cmds: []const tk.cli.Command = &.{
        .usage,
        .cmd0("hello", "Print a greeting message", hello),
        .cmd1("hn", "Show top Hacker News stories", hn_top),
        .cmd1("gh", "List GitHub repos", gh_repos),
        .cmd2("scrape", "Scrape a URL with optional CSS selector", scrape),
        .cmd2("grep", "Search for pattern in file", grep),
        .cmd3("substr", "Get substring with bounds checking", substr),
    },

    fn hello() []const u8 {
        return "Hello World!";
    }

    fn hn_top(hn_client: *tk.hackernews.Client, allocator: std.mem.Allocator, limit: ?u8) ![]const tk.hackernews.Story {
        return hn_client.getTopStories(allocator, limit orelse 10);
    }

    fn gh_repos(gh_client: *tk.github.Client, allocator: std.mem.Allocator, owner: []const u8) ![]const tk.github.Repository {
        return gh_client.listRepos(allocator, owner);
    }

    fn scrape(allocator: std.mem.Allocator, http_client: *tk.http.Client, url: []const u8, qs: ?[]const u8) ![]const u8 {
        const res = try http_client.request(allocator, .{ .url = url });

        const doc = try tk.dom.Document.parseFromSlice(allocator, res.body);
        defer doc.deinit();

        var node = &doc.node;

        if (qs) |sel| {
            if (try doc.querySelector(sel)) |el| node = &el.node;
        }

        return try tk.html2md.html2md(allocator, node, .{});
    }

    fn substr(str: []const u8, start: ?usize, end: ?usize) ![]const u8 {
        if ((start orelse 0) > str.len or (end orelse str.len) > str.len) return error.OutOfBounds;
        return str[start orelse 0 .. end orelse str.len];
    }

    fn grep(allocator: std.mem.Allocator, pattern: []const u8, file_path: []const u8) !void {
        var regex = try tk.regex.Regex.compile(allocator, pattern);
        defer regex.deinit(allocator);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var grepper = tk.regex.Grep.init(&buf, file.reader().any(), &regex);

        while (grepper.next()) |line| {
            std.debug.print("{d}: {s}\n", .{ grepper.line, line });
        }
    }
};

pub fn main() !void {
    std.debug.print(tk.ansi.clear, .{});

    try tk.app.run(tk.cli.run, &.{ App, Cli });
}
