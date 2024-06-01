const std = @import("std");
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;
const Request = @import("request.zig").Request;
const Params = @import("request.zig").Params;

pub const Route = struct {
    method: ?std.http.Method = null,
    prefix: ?[]const u8 = null,
    path: ?[]const u8 = null,
    handler: ?*const Handler = null,
    children: []const Route = &.{},

    pub fn match(self: *const Route, req: *const Request) ?Params {
        if (self.method) |m| {
            if (m != req.method) return null;
        }

        if (self.path) |p| {
            return req.match(p);
        }

        return Params{};
    }
};

/// Group multiple routes under a common prefix.
pub fn group(comptime prefix: []const u8, children: []const Route) Route {
    return .{ .prefix = prefix, .children = children };
}

/// Creates a GET route with the given path and handler.
pub fn get(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.GET, path, false, handler);
}

/// Creates a POST route with the given path and handler. The handler will
/// receive the request body in the last argument.
pub fn post(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.POST, path, true, handler);
}

/// Creates a POST route with the given path and handler but without a body.
pub fn post0(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.POST, path, false, handler);
}

/// Creates a PUT route with the given path and handler. The handler will
/// receive the request body in the last argument.
pub fn put(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.PUT, path, true, handler);
}

/// Creates a PUT route with the given path and handler but without a body.
pub fn put0(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.PUT, path, false, handler);
}

/// Creates a PATCH route with the given path and handler. The handler will
/// receive the request body in the last argument.
pub fn patch(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.PATCH, path, true, handler);
}

/// Creates a PATCH route with the given path and handler but without a body.
pub fn patch0(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.PATCH, path, false, handler);
}

/// Creates a DELETE route with the given path and handler.
pub fn delete(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.DELETE, path, false, handler);
}

/// Creates a group of routes from a struct type. Each pub fn will be equivalent
/// to calling the corresponding route function with the method and path.
pub fn router(comptime T: type) Route {
    const decls = @typeInfo(T).Struct.decls;
    var children: []const Route = &.{};

    for (decls) |d| {
        const j = std.mem.indexOfScalar(u8, d.name, ' ') orelse @compileError("route must contain a space");
        var buf: [j]u8 = undefined;
        const method = std.ascii.lowerString(&buf, d.name[0..j]);
        children = children ++ .{@field(@This(), method)(d.name[j + 1 ..], @field(T, d.name))};
    }

    return .{
        .children = children,
    };
}

fn route(comptime method: std.http.Method, comptime path: []const u8, comptime has_body: bool, comptime handler: anytype) Route {
    const has_query = comptime path[path.len - 1] == '?';
    const n_params = comptime brk: {
        var n: usize = 0;
        for (path) |c| {
            if (c == ':') n += 1;
        }
        break :brk n;
    };

    const H = struct {
        fn handleRoute(ctx: *Context) anyerror!void {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
            const mid = args.len - n_params - @intFromBool(has_query) - @intFromBool(has_body);

            inline for (0..mid) |i| {
                args[i] = try ctx.injector.get(@TypeOf(args[i]));
            }

            inline for (0..n_params, mid..) |j, i| {
                args[i] = try ctx.match.params.get(j, @TypeOf(args[i]));
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
    };

    return .{
        .method = method,
        .path = path[0 .. path.len - @intFromBool(has_query)],
        .handler = H.handleRoute,
    };
}
