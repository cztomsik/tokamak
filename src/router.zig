const std = @import("std");
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;
const chain = @import("middleware.zig").chain;

/// Returns GET handler which can be used as middleware.
pub fn get(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.GET, pattern, false, handler);
}

/// Returns POST handler which can be used as middleware.
pub fn post(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.POST, pattern, true, handler);
}

/// Like `post` but without a body.
pub fn post0(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.POST, pattern, false, handler);
}

/// Returns PUT handler which can be used as middleware.
pub fn put(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.PUT, pattern, true, handler);
}

/// Like `put` but without a body.
pub fn put0(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.PUT, pattern, false, handler);
}

/// Returns PATCH handler which can be used as middleware.
pub fn patch(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.PATCH, pattern, true, handler);
}

/// Like `patch` but without a body.
pub fn patch0(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.PATCH, pattern, false, handler);
}

/// Returns DELETE handler which can be used as middleware.
pub fn delete(comptime pattern: []const u8, comptime handler: anytype) Handler {
    return route(.DELETE, pattern, false, handler);
}

/// Returns middleware which tries to match any of the provided routes.
/// Expects a struct with fn declarations named after the HTTP methods and the
/// route pattern.
pub fn router(comptime routes: type) Handler {
    const decls = @typeInfo(routes).Struct.decls;
    var handlers: [decls.len]Handler = undefined;

    for (decls, 0..) |d, i| {
        const j = std.mem.indexOfScalar(u8, d.name, ' ') orelse @compileError("route must contain a space");
        var buf: [j]u8 = undefined;
        const method = std.ascii.lowerString(&buf, d.name[0..j]);
        handlers[i] = @field(@This(), method)(d.name[j + 1 ..], @field(routes, d.name));
    }

    return chain(handlers);
}

fn route(comptime method: std.http.Method, comptime pattern: []const u8, comptime has_body: bool, comptime handler: anytype) Handler {
    const has_query = comptime std.mem.endsWith(u8, pattern, "?");
    const n_params = comptime std.mem.count(u8, pattern, ":");

    const H = struct {
        fn handleRoute(ctx: *Context) anyerror!void {
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
                    return;
                }
            }

            return ctx.next();
        }
    };
    return H.handleRoute;
}
