const std = @import("std");
const httpz = @import("httpz");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;
const Context = @import("context.zig").Context;
const Handler = @import("context.zig").Handler;
const Schema = @import("schema.zig").Schema;

pub const Route = struct {
    method: ?httpz.Method = null,
    prefix: ?[]const u8 = null,
    path: ?[]const u8 = null,
    handler: ?*const Handler = null,
    children: []const Route = &.{},
    metadata: ?*const Metadata = null,

    const Metadata = struct {
        deps: []const meta.TypeId, // TODO: Server.init() should use this to check if we have all dependencies for all routes.
        params: []const Schema,
        query: ?Schema,
        body: ?Schema,
        result: ?Schema,
        errors: []const anyerror,
    };

    pub fn match(self: *const Route, req: *const httpz.Request) ?Params {
        if (self.prefix) |prefix| {
            if (!std.mem.startsWith(u8, req.url.path, prefix)) return null;
        }

        if (self.method) |m| {
            if (m != req.method) return null;
        }

        if (self.path) |p| {
            return Params.match(p, req.url.path);
        }

        return Params{};
    }

    /// Returns a route that sends the given, comptime response.
    pub fn send(comptime res: anytype) Route {
        const H = struct {
            fn handleSend(ctx: *Context) anyerror!void {
                return ctx.send(res);
            }
        };

        return .{
            .handler = &H.handleSend,
        };
    }

    /// Returns a route that will redirect user somewhere else.
    pub fn redirect(comptime url: []const u8) Route {
        const H = struct {
            fn handleRedirect(ctx: *Context) anyerror!void {
                return ctx.redirect(url, .{});
            }
        };

        return .{
            .handler = &H.handleRedirect,
        };
    }

    /// Groups the given routes under a common prefix. The prefix is removed
    /// from the request path before the children are called.
    pub fn group(prefix: []const u8, children: []const Route) Route {
        const H = struct {
            fn handleGroup(ctx: *Context) anyerror!void {
                const orig = ctx.req.url.path;
                ctx.req.url.path = ctx.req.url.path[ctx.current.prefix.?.len..];
                defer ctx.req.url.path = orig;

                try ctx.next();
            }
        };

        return .{
            .prefix = prefix,
            .handler = H.handleGroup,
            .children = children,
        };
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
        const children = comptime blk: {
            @setEvalBranchQuota(@typeInfo(T).@"struct".decls.len * 100);

            var res: []const Route = &.{};

            for (std.meta.declarations(T)) |d| {
                if (@typeInfo(@TypeOf(@field(T, d.name))) != .@"fn") continue;

                const j = std.mem.indexOfScalar(u8, d.name, ' ') orelse @compileError("route must contain a space");
                var buf: [j]u8 = undefined;
                const method = std.ascii.lowerString(&buf, d.name[0..j]);
                res = res ++ .{@field(@This(), method)(d.name[j + 1 ..], @field(T, d.name))};
            }

            break :blk res;
        };

        return .{
            .children = children,
        };
    }
};

fn route(comptime method: httpz.Method, comptime path: []const u8, comptime has_body: bool, comptime handler: anytype) Route {
    // Special case for putting catch-all routes behind a path.
    if (comptime @TypeOf(handler) == Route) {
        if (handler.metadata) |m| {
            if (m.params.len != 0 or m.query != null or m.body != null) {
                @compileError("Only functions or paramless routes can be used as handlers");
            }
        }

        var copy = handler;
        copy.method = method;
        copy.path = path;
        return copy;
    }

    const metadata: Route.Metadata = comptime routeMetadata(
        path,
        path[path.len - 1] == '?',
        has_body,
        handler,
    );

    return .{
        .method = method,
        .path = path[0 .. path.len - @intFromBool(metadata.query != null)],
        .metadata = &metadata,
        .handler = routeHandler(metadata, handler),
    };
}

fn routeMetadata(comptime path: []const u8, comptime has_query: bool, comptime has_body: bool, comptime handler: anytype) Route.Metadata {
    const fields = std.meta.fields(std.meta.ArgsTuple(@TypeOf(handler)));
    const n_params = comptime brk: {
        var n: usize = 0;
        for (path) |c| {
            if (c == ':') n += 1;
        }
        break :brk n;
    };
    const n_deps = comptime fields.len - n_params - @intFromBool(has_query) - @intFromBool(has_body);

    return .{
        .deps = comptime brk: {
            var deps: [n_deps]meta.TypeId = undefined;
            for (0..n_deps) |i| deps[i] = meta.tid(fields[i].type);
            const res = deps;
            break :brk &res;
        },
        .params = comptime brk: {
            var params: [n_params]Schema = undefined;
            for (0..n_params, n_deps..) |i, j| params[i] = Schema.forType(fields[j].type);
            const res = params;
            break :brk &res;
        },
        .query = if (has_query) Schema.forType(fields[n_deps + n_params].type) else null,
        .body = if (has_body) Schema.forType(fields[fields.len - 1].type) else null,
        .result = switch (meta.Result(handler)) {
            void => null,
            else => |R| Schema.forType(R),
        },
        .errors = comptime brk: {
            switch (@typeInfo(meta.Return(handler))) {
                .error_union => |r| {
                    if (@typeInfo(r.error_set).error_set == null) break :brk &.{};
                    const names = std.meta.fieldNames(r.error_set);
                    var errors: [names.len]anyerror = undefined;
                    for (names, 0..) |e, i| errors[i] = @field(anyerror, e);
                    const res = errors;
                    break :brk &res;
                },
                else => break :brk &.{},
            }
        },
    };
}

fn routeHandler(comptime m: Route.Metadata, comptime handler: anytype) *const Handler {
    const n_deps = m.deps.len;
    const n_params = m.params.len;

    const H = struct {
        fn handleRoute(ctx: *Context) anyerror!void {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;

            inline for (0..n_deps) |i| {
                args[i] = try ctx.injector.get(@TypeOf(args[i]));
            }

            inline for (0..n_params, n_deps..) |j, i| {
                args[i] = try ctx.params.get(j, @TypeOf(args[i]));
            }

            if (comptime m.query != null) {
                args[n_deps + n_params] = try ctx.readQuery(@TypeOf(args[n_deps + n_params]));
            }

            if (comptime m.body != null) {
                args[args.len - 1] = try ctx.readJson(@TypeOf(args[args.len - 1]));
            }

            try ctx.send(@call(.auto, handler, args));
            return;
        }
    };

    return &H.handleRoute;
}

pub const Params = struct {
    matches: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn match(pattern: []const u8, path: []const u8) ?Params {
        var res = Params{};
        var pattern_parts = std.mem.tokenizeScalar(u8, pattern, '/');
        var path_parts = std.mem.tokenizeScalar(u8, path, '/');

        while (true) {
            const pat = pattern_parts.next() orelse return if (pattern[pattern.len - 1] == '*' or path_parts.next() == null) res else null;
            const pth = path_parts.next() orelse return if (pat.len == 1 and pat[0] == '*') res else null;
            const dynamic = pat[0] == ':' or pat[0] == '*';

            if (std.mem.indexOfScalar(u8, pat, '.')) |i| {
                const j = (if (dynamic) std.mem.lastIndexOfScalar(u8, pth, '.') else std.mem.indexOfScalar(u8, pth, '.')) orelse return null;

                if (match(pat[i + 1 ..], pth[j + 1 ..])) |ch| {
                    for (ch.matches, res.len..) |s, l| res.matches[l] = s;
                    res.len += ch.len;
                } else return null;
            }

            if (!dynamic and !std.mem.eql(u8, pat, pth)) return null;

            if (pat[0] == ':') {
                res.matches[res.len] = pth;
                res.len += 1;
            }
        }
    }

    pub fn get(self: *const Params, index: usize, comptime T: type) !T {
        if (index >= self.len) return error.NoMatch;

        return Context.parse(T, self.matches[index]);
    }
};

fn expectMatch(pattern: []const u8, path: []const u8, len: ?usize) !void {
    const res = Params.match(pattern, path);
    if (len) |l| {
        try std.testing.expectEqual(l, res.?.len);
    } else {
        try std.testing.expect(res == null);
    }
}

test "Params matching" {
    try expectMatch("/", "/", 0);
    try expectMatch("/", "/foo", null);
    try expectMatch("/", "/foo/bar", null);

    try expectMatch("/*", "/", 0);
    try expectMatch("/*", "/foo", 0);
    try expectMatch("/*", "/foo/bar", 0);

    try expectMatch("/*.js", "/foo.js", 0);
    try expectMatch("/*.js", "/foo-bar.js", 0);
    try expectMatch("/*.js", "/foo/bar.js", null);
    try expectMatch("/*.js", "/", null);

    try expectMatch("/foo", "/foo", 0);
    try expectMatch("/foo", "/foo/bar", null);
    try expectMatch("/foo", "/bar", null);

    try expectMatch("/:foo", "/foo", 1);
    try expectMatch("/:foo", "/bar", 1);
    try expectMatch("/:foo", "/foo/bar", null);

    try expectMatch("/:foo/bar", "/foo/bar", 1);
    try expectMatch("/:foo/bar", "/baz/bar", 1);
    try expectMatch("/:foo/bar", "/foo/bar/baz", null);

    try expectMatch("/api/*", "/api", 0);
    try expectMatch("/api/*", "/api/foo", 0);
    try expectMatch("/api/*", "/api/foo/bar", 0);
    try expectMatch("/api/*", "/foo", null);
    try expectMatch("/api/*", "/", null);
}
