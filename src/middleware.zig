const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;
const Route = @import("router.zig").Route;

/// Groups the given routes under a common prefix. The prefix is removed
/// from the request path before the children are called.
pub fn group(prefix: []const u8, children: []const Route) Route {
    const H = struct {
        fn handleGroup(ctx: *Context) anyerror!void {
            const orig = ctx.req.path;
            ctx.req.path = ctx.req.path[ctx.current.prefix.?.len..];
            defer ctx.req.path = orig;

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
            var dep = try ctx.injector.call(factory, .{});
            defer if (comptime @hasDecl(DerefType(@TypeOf(dep)), "deinit")) {
                dep.deinit();
            };

            const prev = ctx.injector;
            defer ctx.injector = prev;
            ctx.injector = Injector.fromParent(&prev, &.{&dep});

            try ctx.recur();
        }

        fn DerefType(comptime T: type) type {
            return switch (@typeInfo(T)) {
                .Pointer => |p| p.child,
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
            return ctx.res.send(res);
        }
    };
    return H.handleSend;
}

/// Returns a wrapper for logging all requests going through it.
pub fn logger(options: struct { scope: @TypeOf(.EnumLiteral) = .server }, children: []const Route) Route {
    const log = std.log.scoped(options.scope);

    const H = struct {
        fn handleLogger(ctx: *Context) anyerror!void {
            const start = std.time.milliTimestamp();
            defer if (ctx.res.status) |status| log.debug("{s} {s} {} [{}ms]", .{
                @tagName(ctx.req.head.method),
                ctx.req.head.target,
                @intFromEnum(status),
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
            try ctx.res.setHeader("Access-Control-Allow-Origin", ctx.req.getHeader("Origin") orelse "*");

            if (ctx.req.method == .OPTIONS and ctx.req.getHeader("Access-Control-Request-Headers") != null) {
                try ctx.res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
                try ctx.res.setHeader("Access-Control-Allow-Headers", "Content-Type");
                try ctx.res.setHeader("Access-Control-Allow-Private-Network", "true");
                return ctx.res.sendStatus(.no_content);
            }
        }
    };

    return .{
        .handler = H.handleCors,
    };
}
