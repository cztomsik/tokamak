const std = @import("std");

pub const Post = struct {
    id: u32,
    title: []const u8,
    body: []const u8,
};

pub const BlogService = struct {
    posts: std.AutoArrayHashMap(u32, Post),
    next: std.atomic.Value(u32) = .init(1),

    pub fn init(allocator: std.mem.Allocator) !BlogService {
        var posts = std.AutoArrayHashMap(u32, Post).init(allocator);
        try posts.put(1, .{ .id = 1, .title = "Hello, World!", .body = "This is a test post." });
        try posts.put(2, .{ .id = 2, .title = "Goodbye, World!", .body = "This is another test post." });

        return .{ .posts = posts };
    }

    pub fn getPosts(self: *BlogService, allocator: std.mem.Allocator) ![]const Post {
        var res = std.ArrayList(Post).init(allocator);
        errdefer res.deinit();

        for (self.posts.values()) |post| {
            try res.append(try dupe(allocator, post));
        }

        return res.toOwnedSlice();
    }

    pub fn createPost(self: *BlogService, data: Post) !u32 {
        const post = try dupe(self.posts.allocator, .{
            .id = self.next.fetchAdd(1, .seq_cst),
            .title = data.title,
            .body = data.body,
        });
        try self.posts.put(post.id, post);
        return post.id;
    }

    pub fn getPost(self: *BlogService, allocator: std.mem.Allocator, id: u32) !Post {
        return dupe(allocator, self.posts.get(id) orelse return error.NotFound);
    }

    pub fn updatePost(self: *BlogService, id: u32, data: Post) !void {
        try self.posts.put(id, try dupe(self.posts.allocator, data));
    }

    pub fn deletePost(self: *BlogService, id: u32) !void {
        _ = self.posts.orderedRemove(id);
    }

    fn dupe(allocator: std.mem.Allocator, post: Post) !Post {
        return .{
            .id = post.id,
            .title = try allocator.dupe(u8, post.title),
            .body = try allocator.dupe(u8, post.body),
        };
    }
};
