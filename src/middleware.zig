const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Context = @import("context.zig").Context;
const Handler = @import("context.zig").Handler;
const Route = @import("route.zig").Route;

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

            try ctx.nextScoped(&child);
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
