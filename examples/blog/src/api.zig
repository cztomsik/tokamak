const std = @import("std");
const Post = @import("model.zig").Post;
const BlogService = @import("model.zig").BlogService;

pub fn @"GET /posts"(svc: *BlogService, allocator: std.mem.Allocator) ![]const Post {
    return svc.getPosts(allocator);
}

pub fn @"POST /posts"(svc: *BlogService, data: Post) !u32 {
    return svc.createPost(data);
}

pub fn @"GET /posts/:id"(svc: *BlogService, allocator: std.mem.Allocator, id: u32) !Post {
    return svc.getPost(allocator, id);
}

pub fn @"PUT /posts/:id"(svc: *BlogService, id: u32, data: Post) !void {
    try svc.updatePost(id, data);
}

pub fn @"DELETE /posts/:id"(svc: *BlogService, id: u32) !void {
    try svc.deletePost(id);
}
