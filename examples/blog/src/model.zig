const std = @import("std");

pub const Post = struct {
    id: u32,
    title: []const u8,
    body: []const u8,
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

// Simple in-memory cache
pub const Cache = struct {
    posts: std.AutoHashMap(u32, CachedPost),
    mutex: std.Thread.Mutex = .{},

    const CachedPost = struct {
        post: Post,
        cached_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .posts = std.AutoHashMap(u32, CachedPost).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.posts.iterator();
        while (it.next()) |entry| {
            self.posts.allocator.free(entry.value_ptr.post.title);
            self.posts.allocator.free(entry.value_ptr.post.body);
        }
        self.posts.deinit();
    }

    pub fn get(self: *Cache, allocator: std.mem.Allocator, id: u32) !?Post {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cached = self.posts.get(id) orelse return null;

        // Simple TTL: 60 seconds
        const now = std.time.timestamp();
        if (now - cached.cached_at > 60) {
            _ = self.posts.remove(id);
            return null;
        }

        return try dupe(allocator, cached.post);
    }

    pub fn put(self: *Cache, id: u32, post: Post) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cached_post = CachedPost{
            .post = try dupe(self.posts.allocator, post),
            .cached_at = std.time.timestamp(),
        };
        try self.posts.put(id, cached_post);
    }

    pub fn invalidate(self: *Cache, id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.posts.remove(id);
    }

    pub fn invalidateAll(self: *Cache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.posts.clearRetainingCapacity();
    }

    fn dupe(allocator: std.mem.Allocator, post: Post) !Post {
        return .{
            .id = post.id,
            .title = try allocator.dupe(u8, post.title),
            .body = try allocator.dupe(u8, post.body),
            .created_at = post.created_at,
            .updated_at = post.updated_at,
        };
    }
};

// Validation service
pub const Validator = struct {
    pub fn init() Validator {
        return .{};
    }

    pub fn validatePost(self: *Validator, post: Post) !void {
        _ = self;
        if (post.title.len == 0) return error.TitleRequired;
        if (post.title.len > 200) return error.TitleTooLong;
        if (post.body.len == 0) return error.BodyRequired;
        if (post.body.len > 10000) return error.BodyTooLong;
    }
};

pub const BlogService = struct {
    posts: std.AutoArrayHashMap(u32, Post),
    next: std.atomic.Value(u32) = .init(1),
    cache: *Cache,
    validator: *Validator,

    pub fn init(allocator: std.mem.Allocator, cache: *Cache, validator: *Validator) !BlogService {
        var posts = std.AutoArrayHashMap(u32, Post).init(allocator);

        const now = std.time.timestamp();
        try posts.put(1, .{
            .id = 1,
            .title = "Welcome to the Blog API",
            .body = "This is a modern blog API with caching and validation.",
            .created_at = now,
            .updated_at = now,
        });
        try posts.put(2, .{
            .id = 2,
            .title = "Dependency Injection in Zig",
            .body = "Learn how to use DI effectively in your Zig applications.",
            .created_at = now,
            .updated_at = now,
        });

        return .{
            .posts = posts,
            .cache = cache,
            .validator = validator,
        };
    }

    pub fn deinit(self: *BlogService) void {
        // Free all duplicated strings in posts
        for (self.posts.values()) |post| {
            self.posts.allocator.free(post.title);
            self.posts.allocator.free(post.body);
        }
        self.posts.deinit();
    }

    pub fn getPosts(self: *BlogService, allocator: std.mem.Allocator) ![]const Post {
        var res = std.ArrayList(Post){};
        errdefer res.deinit(allocator);

        for (self.posts.values()) |post| {
            try res.append(allocator, try dupe(allocator, post));
        }

        return res.toOwnedSlice(allocator);
    }

    pub fn createPost(self: *BlogService, data: Post) !u32 {
        // Validate first
        try self.validator.validatePost(data);

        const now = std.time.timestamp();
        const post = try dupe(self.posts.allocator, .{
            .id = self.next.fetchAdd(1, .monotonic),
            .title = data.title,
            .body = data.body,
            .created_at = now,
            .updated_at = now,
        });
        try self.posts.put(post.id, post);

        // Invalidate cache
        self.cache.invalidateAll();

        return post.id;
    }

    pub fn getPost(self: *BlogService, allocator: std.mem.Allocator, id: u32) !Post {
        // Try cache first
        if (try self.cache.get(allocator, id)) |cached| {
            return cached;
        }

        // Cache miss - get from store
        const post = try dupe(allocator, self.posts.get(id) orelse return error.NotFound);

        // Update cache
        try self.cache.put(id, post);

        return post;
    }

    pub fn updatePost(self: *BlogService, id: u32, data: Post) !void {
        // Validate first
        try self.validator.validatePost(data);

        const existing = self.posts.get(id) orelse return error.NotFound;

        const updated = try dupe(self.posts.allocator, .{
            .id = id,
            .title = data.title,
            .body = data.body,
            .created_at = existing.created_at,
            .updated_at = std.time.timestamp(),
        });

        try self.posts.put(id, updated);

        // Invalidate cache for this post
        self.cache.invalidate(id);
    }

    pub fn deletePost(self: *BlogService, id: u32) !void {
        _ = self.posts.orderedRemove(id);
        self.cache.invalidate(id);
    }

    fn dupe(allocator: std.mem.Allocator, post: Post) !Post {
        return .{
            .id = post.id,
            .title = try allocator.dupe(u8, post.title),
            .body = try allocator.dupe(u8, post.body),
            .created_at = post.created_at,
            .updated_at = post.updated_at,
        };
    }
};
