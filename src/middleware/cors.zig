const Route = @import("../route.zig").Route;
const Context = @import("../context.zig").Context;

/// Adds CORS headers and handles preflight requests. Note that headers cannot
/// be removed so this should always wrapped in a group.
pub fn cors() Route {
    const H = struct {
        fn handleCors(ctx: *Context) anyerror!void {
            ctx.res.header("access-control-allow-origin", ctx.req.header("origin") orelse "*");

            if (ctx.req.method == .OPTIONS and ctx.req.header("access-control-request-method") != null) {
                ctx.res.header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS");
                ctx.res.header("access-control-allow-headers", "content-type");
                ctx.res.header("access-control-allow-private-network", "true");
                return ctx.send(void{});
            }
        }
    };

    return .{
        .handler = H.handleCors,
    };
}
