const std = @import("std");
const tk = @import("tokamak");

// Shared
const App = struct {
    http_client: tk.http.StdClient,
    hn_client: tk.ext.hackernews.Client,
    gh_client: tk.ext.github.Client,
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
        .cmd2("pdf", "Generate a sample PDF", writePdf),
    },

    fn hello() []const u8 {
        return "Hello World!";
    }

    fn hn_top(hn_client: *tk.ext.hackernews.Client, arena: std.mem.Allocator, limit: ?u8) ![]const tk.ext.hackernews.Story {
        return hn_client.getTopStories(arena, limit orelse 10);
    }

    fn gh_repos(gh_client: *tk.ext.github.Client, arena: std.mem.Allocator, owner: []const u8) ![]const tk.ext.github.Repository {
        return gh_client.listRepos(arena, owner);
    }

    fn scrape(http_client: *tk.http.Client, arena: std.mem.Allocator, url: []const u8, qs: ?[]const u8) ![]const u8 {
        const res = try http_client.request(arena, .{ .url = url });

        const doc = try tk.dom.Document.parseFromSlice(arena, res.body);
        defer doc.deinit();

        var node = &doc.node;

        if (qs) |sel| {
            if (try doc.querySelector(sel)) |el| node = &el.node;
        }

        return try tk.html2md.html2md(arena, node, .{});
    }

    fn substr(str: []const u8, start: ?usize, end: ?usize) ![]const u8 {
        if ((start orelse 0) > str.len or (end orelse str.len) > str.len) return error.OutOfBounds;
        return str[start orelse 0 .. end orelse str.len];
    }

    fn writePdf(arena: std.mem.Allocator, filename: []const u8, title: []const u8) !void {
        var doc = try tk.pdf.Document.init(arena);
        defer doc.deinit();

        var page = try doc.addPage(612, 792);

        try page.addText(50, 750, title, .{ .size = 24, .bold = true });
        try page.addText(50, 730, try std.fmt.allocPrint(arena, "Generated on: {f}", .{
            tk.time.Date.today(),
        }), .{ .size = 10 });
        try page.addLine(50, 710, 550, 710);

        try page.addRect(50, 600, 100, 50);
        try page.addText(160, 620, "Rectangle", .{ .bold = true });

        try page.moveTo(50, 500);
        try page.lineTo(100, 550);
        try page.lineTo(150, 500);
        try page.closePath();
        try page.stroke();
        try page.addText(160, 520, "Triangle", .{ .bold = true });

        try page.moveTo(50, 450);
        try page.curveTo(75, 400, 125, 400, 150, 450);
        try page.stroke();
        try page.addText(160, 420, "Curve", .{ .bold = true });

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(try doc.render(arena));

        std.debug.print("PDF '{s}' generated successfully", .{filename});
    }

    fn grep(arena: std.mem.Allocator, file_path: []const u8, pattern: []const u8) !void {
        var regex = try tk.regex.Regex.compile(arena, pattern);
        defer regex.deinit(arena);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var in = file.reader(&buf);
        var grepper = tk.regex.Grep.init(&in.interface, &regex);

        while (try grepper.next()) |line| {
            std.debug.print("{d}: {s}", .{ grepper.line, line });
        }
    }
};

pub fn main() !void {
    std.debug.print(tk.ansi.clear, .{});

    try tk.app.run(tk.cli.run, &.{ App, Cli });
}
