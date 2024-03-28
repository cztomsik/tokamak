const std = @import("std");
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;

/// Returns GET handler which can be used as middleware.
pub fn get(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.GET, pattern, handler);
}

/// Returns POST handler which can be used as middleware.
pub fn post(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.POST, pattern, handler);
}

/// Returns PUT handler which can be used as middleware.
pub fn put(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.PUT, pattern, handler);
}

/// Returns PATCH handler which can be used as middleware.
pub fn patch(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.PATCH, pattern, handler);
}

/// Returns DELETE handler which can be used as middleware.
pub fn delete(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.DELETE, pattern, handler);
}

/// Returns middleware which tries to match any of the provided routes.
/// Expects a struct with fn declarations named after the HTTP methods and the
/// route pattern.
pub fn router(comptime routes: type) Handler {
    const H = struct {
        fn handleRoutes(ctx: *Context) anyerror!void {
            inline for (@typeInfo(routes).Struct.decls) |d| {
                if (comptime @typeInfo(@TypeOf(@field(routes, d.name))) != .Fn) continue;

                const i = comptime std.mem.indexOfScalar(u8, d.name, ' ') orelse @compileError("route must contain a space");
                const method = comptime @field(std.http.Method, d.name[0..i]);
                const pattern = comptime d.name[i + 1 ..];
                const handler = comptime @field(routes, d.name);

                if (try matchRoute(ctx, method, pattern, handler)) {
                    return;
                }
            }

            return ctx.next();
        }
    };
    return H.handleRoutes;
}

fn route(comptime method: std.http.Method, comptime pattern: []const u8, comptime handler: anytype) Handler {
    const H = struct {
        fn handleRoute(ctx: *Context) anyerror!void {
            if (!try matchRoute(ctx, method, pattern, handler)) {
                return ctx.next();
            }
        }
    };
    return H.handleRoute;
}

fn matchRoute(ctx: *Context, comptime method: std.http.Method, comptime pattern: []const u8, comptime handler: anytype) anyerror!bool {
    const has_body: u1 = comptime if (method == .POST or method == .PUT or method == .PATCH) 1 else 0;
    const param_count = comptime std.mem.count(u8, pattern, ":") + has_body;

    if (ctx.req.method == method) {
        if (ctx.req.match(pattern)) |params| {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
            const mid = args.len - param_count;

            inline for (0..mid) |i| {
                args[i] = try ctx.injector.get(@TypeOf(args[i]));
            }

            inline for (mid..args.len) |i| {
                const V = @TypeOf(args[i]);
                args[i] = try if (comptime @typeInfo(V) == .Struct) ctx.req.readJson(V) else params.get(i - mid, V);
            }

            try ctx.res.send(@call(.auto, handler, args));
            return true;
        }
    }

    return false;
}
