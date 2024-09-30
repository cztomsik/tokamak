const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Context = @import("context.zig").Context;
const Handler = @import("context.zig").Handler;
const Route = @import("router.zig").Route;

/// Groups the given routes under a common prefix. The prefix is removed
/// from the request path before the children are called.
pub fn group(prefix: []const u8, children: []const Route) Route {
    const H = struct {
        fn handleGroup(ctx: *Context) anyerror!void {
            const orig = ctx.req.url.path;
            ctx.req.url.path = ctx.req.url.path[ctx.current.prefix.?.len..];
            defer ctx.req.url.path = orig;

            try ctx.recur();
        }
    };

    return .{
        .prefix = prefix,
        .handler = H.handleGroup,
        .children = children,
    };
}

/// Call the factory and provide result to all children. The factory can
/// use the current scope to resolve its own dependencies. If the resulting
/// type has a `deinit` method, it will be called at the end of the scope.
pub fn provide(comptime factory: anytype, children: []const Route) Route {
    const H = struct {
        fn handleProvide(ctx: *Context) anyerror!void {
            var child = .{try ctx.injector.call(factory, .{})};
            defer if (comptime @hasDecl(DerefType(@TypeOf(child[0])), "deinit")) {
                child[0].deinit();
            };

            try ctx.recurScoped(&child);
        }

        fn DerefType(comptime T: type) type {
            return switch (@typeInfo(T)) {
                .pointer => |p| p.child,
                else => T,
            };
        }
    };

    return .{
        .handler = H.handleProvide,
        .children = children,
    };
}

/// Returns a handler that sends the given, comptime response.
pub fn send(comptime res: anytype) Handler {
    const H = struct {
        fn handleSend(ctx: *Context) anyerror!void {
            return ctx.send(res);
        }
    };
    return H.handleSend;
}

/// Returns a handler that will redirect user somewhere else.
pub fn redirect(comptime url: []const u8) Handler {
    const H = struct {
        fn handleRedirect(ctx: *Context) anyerror!void {
            return ctx.redirect(url, .{});
        }
    };
    return H.handleRedirect;
}

/// Returns a wrapper for logging all requests going through it.
pub fn logger(options: struct { scope: @TypeOf(.EnumLiteral) = .server }, children: []const Route) Route {
    const log = std.log.scoped(options.scope);

    const H = struct {
        fn handleLogger(ctx: *Context) anyerror!void {
            const start = std.time.milliTimestamp();
            defer if (ctx.responded) log.debug("{s} {s} {} [{}ms]", .{
                @tagName(ctx.req.method),
                ctx.req.url.path,
                ctx.res.status,
                std.time.milliTimestamp() - start,
            });

            try ctx.recur();
        }
    };

    return .{
        .handler = H.handleLogger,
        .children = children,
    };
}

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
