const std = @import("std");
const tk = @import("tokamak");

// Shared
const App = struct {
    http_client: tk.http.StdClient,
};

// CLI-only
const Cli = struct {
    cmds: []const tk.cli.Command = &.{
        .usage,
        .cmd0("hello", "Print a greeting message", hello),
        .cmd2("scrape", "Scrape a URL with optional CSS selector", scrape),
        .cmd2("grep", "Search for pattern in file", grep),
        .cmd3("substr", "Get substring with bounds checking", substr),
    },

    fn hello() []const u8 {
        return "Hello World!";
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

    fn grep(io: std.Io, arena: std.mem.Allocator, file_path: []const u8, pattern: []const u8) !void {
        var regex = try tk.regex.Regex.compile(arena, pattern);
        defer regex.deinit(arena);

        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var in = file.reader(io, &buf);
        var grepper = tk.regex.Grep.init(&in.interface, &regex);

        while (try grepper.next()) |line| {
            std.debug.print("{d}: {s}", .{ grepper.line, line });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    try tk.app.run(init, tk.cli.run, &.{ App, Cli });
}
