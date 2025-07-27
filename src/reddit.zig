const std = @import("std");
const http = @import("http.zig");
const testing = @import("testing.zig");

pub const Config = struct {
    base_url: []const u8 = "https://www.reddit.com/",
    timeout: ?usize = 2 * 60,
};

pub const Post = struct {
    id: []const u8,
    title: []const u8,
    author: []const u8,
    subreddit: []const u8,
    // url: ?[]const u8 = null,
    // selftext: ?[]const u8 = null,
    score: i64 = 0,
    num_comments: u64 = 0,
    created_utc: f64 = 0,
    // permalink: []const u8,
    is_self: bool = false,
};

pub const RedditResponse = struct {
    data: struct {
        children: []struct {
            data: Post,
        },
    },
};

pub const Client = struct {
    http_client: *http.Client,
    config: Config = .{},

    pub fn getHotPosts(self: *Client, arena: std.mem.Allocator, sub: []const u8, limit: u32) ![]const Post {
        return self.getPosts(arena, sub, "hot", limit);
    }

    pub fn getNewPosts(self: *Client, arena: std.mem.Allocator, sub: []const u8, limit: u32) ![]const Post {
        return self.getPosts(arena, sub, "new", limit);
    }

    pub fn getTopPosts(self: *Client, arena: std.mem.Allocator, sub: []const u8, limit: u32) ![]const Post {
        return self.getPosts(arena, sub, "top", limit);
    }

    fn getPosts(self: *Client, arena: std.mem.Allocator, sub: []const u8, sort: []const u8, limit: u32) ![]const Post {
        const path = try std.fmt.allocPrint(arena, "r/{s}/{s}.json?limit={}", .{ sub, sort, limit });

        const response = try self.http_client.request(arena, .{
            .base_url = self.config.base_url,
            .url = path,
            .timeout = self.config.timeout,
        });

        const res = try response.json(RedditResponse);
        const posts = try arena.alloc(Post, res.data.children.len);

        for (res.data.children, 0..) |child, i| {
            posts[i] = child.data;
        }

        return posts;
    }
};

test {
    const mock, const http_client = try testing.httpClient();
    defer mock.deinit();

    var reddit_client = Client{ .http_client = http_client };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try mock.expectNext("200 GET r/foo/hot.json?limit=10",
        \\{
        \\  "data": {
        \\    "children": [
        \\      {
        \\        "data": {
        \\          "id": "123",
        \\          "title": "First",
        \\          "author": "usr1",
        \\          "subreddit": "Zig",
        \\          "score": 1,
        \\          "num_comments": 123,
        \\          "permalink": "/r/foo/xxx",
        \\          "is_self": true
        \\        }
        \\      },
        \\      {
        \\        "data": {
        \\          "id": "456",
        \\          "title": "Second",
        \\          "author": "usr2",
        \\          "subreddit": "Zig",
        \\          "score": 2,
        \\          "num_comments": 456,
        \\          "permalink": "/r/foo/yyy",
        \\          "is_self": false
        \\        }
        \\      }
        \\    ]
        \\  }
        \\}
    );

    const posts = try reddit_client.getHotPosts(arena.allocator(), "foo", 10);

    try testing.expectTable(posts,
        \\| id   | title  | author | subreddit | score | num_comments | is_self |
        \\|------|--------|--------|-----------|-------|--------------|---------|
        \\| 123  | First  | usr1   | Zig       | 1     | 123          | true    |
        \\| 456  | Second | usr2   | Zig       | 2     | 456          | false   |
    );
}
