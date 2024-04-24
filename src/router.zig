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
    const has_body = comptime method == .POST or method == .PUT or method == .PATCH;
    const has_query = comptime std.mem.endsWith(u8, pattern, "?");
    const n_params = comptime std.mem.count(u8, pattern, ":");

    if (ctx.req.method == method) {
        if (ctx.req.match(comptime pattern[0 .. pattern.len - @intFromBool(has_query)])) |params| {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
            const mid = args.len - n_params - @intFromBool(has_query) - @intFromBool(has_body);

            inline for (0..mid) |i| {
                args[i] = try ctx.injector.get(@TypeOf(args[i]));
            }

            inline for (0..n_params, mid..) |j, i| {
                args[i] = try params.get(j, @TypeOf(args[i]));
            }

            if (comptime has_query) {
                args[mid + n_params] = try ctx.req.readQuery(@TypeOf(args[mid + n_params]));
            }

            if (comptime has_body) {
                args[args.len - 1] = try ctx.req.readJson(@TypeOf(args[args.len - 1]));
            }

            try ctx.res.send(@call(.auto, handler, args));
            return true;
        }
    }

    return false;
}
