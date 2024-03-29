const builtin = @import("builtin");
const root = @import("root");
const std = @import("std");
const mime = @import("mime.zig").mime;
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;

// TODO: serveStatic() and come up with a different solution for embedding.
//       maybe we should by default pretend to serve static files from a directory
//       and then have a way to override that with a custom handler.
//       or maybe we can pass some glob patterns to the library build options?

// TODO: both should delegate to a overridable function that can do embedding.

/// Sends a static resource. The resource is embedded in release builds.
pub fn sendStatic(comptime path: []const u8) Handler {
    const H = struct {
        pub fn handleStatic(ctx: *Context) anyerror!void {
            try ctx.res.setHeader("Content-Type", comptime mime(std.fs.path.extension(path)) ++ "; charset=utf-8");
            try ctx.res.noCache();

            try ctx.res.sendChunk(if (comptime builtin.mode != .Debug) root.embedFile(path) else blk: {
                var f = try std.fs.cwd().openFile(path, .{});
                defer f.close();
                break :blk try f.readToEndAlloc(ctx.allocator, std.math.maxInt(usize));
            });
        }
    };
    return H.handleStatic;
}
