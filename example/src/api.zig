const std = @import("std");

pub const Post = struct {
    id: u32,
    title: []const u8,
    body: []const u8,
};

pub const Store = std.AutoHashMap(u32, Post);

pub fn @"GET /posts"(allocator: std.mem.Allocator, store: *Store) ![]Post {
    var res = std.ArrayList(Post).init(allocator);
    var it = store.valueIterator();
    while (it.next()) |post| try res.append(post.*);

    return res.toOwnedSlice();
}

pub fn @"POST /posts"(store: *Store, data: Post) !void {
    const post = .{
        .id = store.count() + 1,
        .title = try store.allocator.dupe(u8, data.title),
        .body = try store.allocator.dupe(u8, data.body),
    };

    try store.put(post.id, post);
}

pub fn @"GET /posts/:id"(store: *Store, id: u32) !Post {
    return store.get(id) orelse error.NotFound;
}

pub fn @"PUT /posts/:id"(store: *Store, id: u32, data: Post) !void {
    if (store.getPtr(id)) |post| {
        post.title = try store.allocator.dupe(u8, data.title);
        post.body = try store.allocator.dupe(u8, data.body);
    }
}

pub fn @"DELETE /posts/:id"(store: *Store, id: u32) !void {
    _ = store.remove(id);
}
