const std = @import("std");
const tk = @import("tokamak");

pub const Post = struct {
    id: u32,
    title: []const u8,
    body: []const u8,
};

pub const BlogService = struct {
    gpa: std.mem.Allocator,
    posts: std.array_hash_map.Auto(u32, Post) = .empty,
    next: std.atomic.Value(u32) = .init(1),

    pub fn init(gpa: std.mem.Allocator) !BlogService {
        var self = BlogService{ .gpa = gpa };
        _ = try self.createPost(.{ .id = 1, .title = "Hello, World!", .body = "This is a test post." });
        _ = try self.createPost(.{ .id = 2, .title = "Goodbye, World!", .body = "This is another test post." });
        return self;
    }

    pub fn deinit(self: *BlogService) void {
        // Free all duplicated strings in posts
        for (self.posts.values()) |post| tk.meta.free(self.gpa, post);
        self.posts.deinit(self.gpa);
    }

    pub fn getPosts(self: *BlogService, allocator: std.mem.Allocator) ![]const Post {
        var res: std.ArrayList(Post) = .empty;
        errdefer res.deinit(allocator);

        for (self.posts.values()) |post| {
            try res.append(allocator, try tk.meta.dupe(allocator, post));
        }

        return res.toOwnedSlice(allocator);
    }

    pub fn createPost(self: *BlogService, data: Post) !u32 {
        const post = try tk.meta.dupe(self.gpa, Post{
            .id = self.next.fetchAdd(1, .monotonic),
            .title = data.title,
            .body = data.body,
        });
        try self.posts.put(self.gpa, post.id, post);
        return post.id;
    }

    pub fn getPost(self: *BlogService, allocator: std.mem.Allocator, id: u32) !Post {
        return tk.meta.dupe(allocator, self.posts.get(id) orelse return error.NotFound);
    }

    pub fn updatePost(self: *BlogService, id: u32, data: Post) !void {
        try self.posts.put(self.gpa, id, try tk.meta.dupe(self.gpa, data));
    }

    pub fn deletePost(self: *BlogService, id: u32) !void {
        _ = self.posts.orderedRemove(id);
    }
};
