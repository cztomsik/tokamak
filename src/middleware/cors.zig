const Route = @import("../route.zig").Route;
const Context = @import("../context.zig").Context;

/// Adds CORS headers and handles preflight requests. Note that headers cannot
/// be removed so this should always be wrapped in a group.
pub fn cors() Route {
    const H = struct {
        fn handleCors(ctx: *Context) anyerror!void {
            try ctx.res.header("access-control-allow-origin", ctx.req.headers.get("origin") orelse "*");

            if (ctx.req.method == .options and ctx.req.headers.get("access-control-request-method") != null) {
                try ctx.res.header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS");
                try ctx.res.header("access-control-allow-headers", "content-type");
                try ctx.res.header("access-control-allow-private-network", "true");
                return ctx.send({});
            }
        }
    };

    return .{
        .handler = H.handleCors,
    };
}
