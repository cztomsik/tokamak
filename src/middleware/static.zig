const builtin = @import("builtin");
const embed = @import("embed");
const std = @import("std");
const mime = @import("../mime.zig").mime;
const Route = @import("../route.zig").Route;
const Context = @import("../context.zig").Context;

const E: std.StaticStringMap([]const u8) = if (builtin.mode == .Debug) .{} else .initComptime(kvs: {
    var res: [embed.files.len]struct { []const u8, []const u8 } = undefined;
    for (embed.files, embed.contents, 0..) |f, c, i| res[i] = .{ f, c };
    break :kvs &res;
});

const DirOptions = struct {
    index: ?[]const u8 = "index.html",
};

pub fn dir(comptime path: []const u8, comptime options: DirOptions) Route {
    const H = struct {
        pub fn handleDir(ctx: *Context) anyerror!void {
            // We only support GET for now
            if (ctx.req.method != .GET) return;

            var target = ctx.req.url.path;

            // Strip the prefix if we are inside of Route.get("/xxx/*")
            if (ctx.current.path) |p| {
                std.debug.assert(p.len >= 2);
                std.debug.assert(ctx.params.len == 0);
                target = target[p.len - 2 ..];
            }

            // Map / to index file
            if (options.index != null and target.len == 1 and target[0] == '/') {
                target = options.index.?;
            }

            // Resolve relative paths (this is important for the check below to work)
            target = try std.fs.path.resolvePosix(ctx.allocator, &.{ path, std.mem.trimLeft(u8, target, "/") });

            // Prevent (out-of-directory) traversal attacks
            if (!std.mem.startsWith(u8, target, path)) {
                return;
            }

            return sendFile(ctx, target) catch |e| return switch (e) {
                error.FileNotFound => {},
                else => e,
            };
        }
    };

    return .{
        .handler = &H.handleDir,
    };
}

pub fn file(comptime path: []const u8) Route {
    const H = struct {
        pub fn handleFile(ctx: *Context) anyerror!void {
            return sendFile(ctx, path) catch |e| return switch (e) {
                error.FileNotFound => {},
                else => e,
            };
        }
    };

    return .{
        .handler = &H.handleFile,
    };
}

fn sendFile(ctx: *Context, target: []const u8) !void {
    const body = if (E.get(target)) |e| e else try std.fs.cwd().readFileAlloc(ctx.allocator, target, std.math.maxInt(usize));

    ctx.res.header("content-type", try content_type(ctx.allocator, target));
    ctx.res.header("cache-control", "no-cache, no-store, must-revalidate");

    ctx.res.body = body;
    ctx.responded = true;
}

// TODO: maybe we could just ctx.res.content_type = .forFile(target) in the future...
fn content_type(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    var res = mime(std.fs.path.extension(target));

    if (std.mem.startsWith(u8, res, "text/") or std.mem.eql(u8, res, "application/json")) {
        res = try std.fmt.allocPrint(allocator, "{s}; charset=utf-8", .{res});
    }

    return res;
}
