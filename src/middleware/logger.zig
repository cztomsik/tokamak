const std = @import("std");
const Route = @import("../route.zig").Route;
const Context = @import("../context.zig").Context;

/// Returns a wrapper for logging all requests going through it.
pub fn logger(options: struct { scope: @TypeOf(.EnumLiteral) = .server }, children: []const Route) Route {
    const log = std.log.scoped(options.scope);

    const H = struct {
        fn handleLogger(ctx: *Context) anyerror!void {
            const start = std.Io.Timestamp.now(ctx.server.http.io, .awake);
            defer if (ctx.responded) log.debug("{s} {s} {} [{}ms]", .{
                @tagName(ctx.req.method),
                ctx.req.url.path,
                ctx.res.status,
                start.untilNow(ctx.server.http.io, .awake).toMilliseconds(),
            });

            try ctx.next();
        }
    };

    return .{
        .handler = H.handleLogger,
        .children = children,
    };
}
