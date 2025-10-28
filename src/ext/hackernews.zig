const std = @import("std");
const http = @import("../http.zig");
const testing = @import("../testing.zig");

pub const Config = struct {
    base_url: []const u8 = "https://hacker-news.firebaseio.com/v0/",
    timeout: ?usize = 2 * 60,
};

// TODO: aiStringify() or maybe some mask should be passed during agr.addTool()?
pub const Story = struct {
    id: u64,
    parent: ?u64 = null,
    type: []const u8,
    by: []const u8,
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    text: ?[]const u8 = null,
    kids: ?[]const u64 = null,
    descendants: u64 = 0,
    time: u64 = 0,
};

pub const Client = struct {
    http_client: *http.Client,
    config: Config = .{},

    pub fn getTopStories(self: *Client, arena: std.mem.Allocator, limit: u9) ![]const Story {
        return self.getStories(arena, "topstories.json", limit);
    }

    pub fn getNewStories(self: *Client, arena: std.mem.Allocator, limit: u9) ![]const Story {
        return self.getStories(arena, "newstories.json", limit);
    }

    pub fn getBestStories(self: *Client, arena: std.mem.Allocator, limit: u9) ![]const Story {
        return self.getStories(arena, "beststories.json", limit);
    }

    fn getStories(self: *Client, arena: std.mem.Allocator, path: []const u8, limit: u9) ![]const Story {
        const ids_res = try self.http_client.request(arena, .{
            .base_url = self.config.base_url,
            .url = path,
            .timeout = self.config.timeout,
        });

        const ids = try ids_res.json([]const u64);
        const res = try arena.alloc(Story, @min(limit, ids.len));

        for (ids[0..res.len], 0..) |id, i| {
            const file = try std.fmt.allocPrint(arena, "item/{}.json", .{id});
            const story_res = try self.http_client.request(arena, .{
                .base_url = self.config.base_url,
                .url = file,
                .timeout = self.config.timeout,
            });

            res[i] = try story_res.json(Story);
        }

        return res;
    }
};

test {
    const mock, const http_client = try testing.httpClient();
    defer mock.deinit();

    var hn_client = Client{ .http_client = http_client };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try mock.expectNext("200 GET topstories.json", "[1,2]");
    try mock.expectNext("200 GET item/1.json", "{\"id\":1,\"type\":\"story\",\"by\":\"foo\"}");
    try mock.expectNext("200 GET item/2.json", "{\"id\":2,\"type\":\"ask\",\"by\":\"bar\"}");

    const stories = try hn_client.getTopStories(arena.allocator(), 3);

    try testing.expectTable(stories,
        \\| id | type  | by   |
        \\|----|-------|------|
        \\| 1  | story | foo  |
        \\| 2  | ask   | bar  |
    );
}
