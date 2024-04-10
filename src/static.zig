const builtin = @import("builtin");
const embed = @import("embed");
const std = @import("std");
const mime = @import("mime.zig").mime;
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;

const E = std.ComptimeStringMap([]const u8, kvs: {
    var res: [embed.files.len]struct { []const u8, []const u8 } = undefined;
    for (embed.files, embed.contents, 0..) |f, c, i| res[i] = .{ f, c };
    break :kvs &res;
});

// TODO: serveStatic(dir)

/// Sends a static resource.
pub fn sendStatic(comptime path: []const u8) Handler {
    const H = struct {
        pub fn handleStatic(ctx: *Context) anyerror!void {
            // TODO: charset should only be set for text files.
            try ctx.res.setHeader("Content-Type", comptime mime(std.fs.path.extension(path)) ++ "; charset=utf-8");
            try ctx.res.noCache();

            var body = E.get(path);

            if (body == null or comptime builtin.mode == .Debug) {
                body = try std.fs.cwd().readFileAlloc(ctx.allocator, path, std.math.maxInt(usize));
            }

            try ctx.res.sendChunk(body.?);
        }
    };
    return H.handleStatic;
}
