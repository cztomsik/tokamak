const std = @import("std");
const httpz = @import("httpz");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;
const Server = @import("server.zig").Server;
const Route = @import("route.zig").Route;
const Params = @import("route.zig").Params;
const Schema = @import("schema.zig").Schema;
const log = std.log.scoped(.tokamak);

pub const Handler = fn (*Context) anyerror!void;

pub const Context = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
    current: Route,
    params: Params,
    injector: Injector,
    responded: bool = false,

    /// Get value from a string.
    pub fn parse(self: *Context, comptime T: type, s: []const u8) !T {
        return switch (@typeInfo(T)) {
            .optional => |o| if (std.mem.eql(u8, s, "null")) null else try self.parse(o.child, s),
            .bool => std.mem.eql(u8, s, "true"),
            .int => std.fmt.parseInt(T, s, 10),
            .@"enum" => std.meta.stringToEnum(T, s) orelse error.InvalidEnumTag,
            .pointer => |p| {
                if (comptime meta.isString(T)) return s;

                if (p.size == .slice) {
                    var res = std.ArrayList(p.child).init(self.req.arena);
                    var it = std.mem.splitScalar(u8, s, ',');
                    while (it.next()) |part| {
                        try res.append(try self.parse(p.child, part));
                    }
                    return res.items;
                }

                @compileError("Not supported");
            },
            else => @compileError("Not supported"),
        };
    }

    /// Reads the query parameters into a struct.
    pub fn readQuery(self: *Context, comptime T: type) !T {
        const query = try self.req.query();
        var res: T = undefined;

        inline for (std.meta.fields(T)) |f| {
            if (query.get(f.name)) |param| {
                @field(res, f.name) = try self.parse(f.type, param);
            } else if (f.default_value_ptr) |ptr| {
                @field(res, f.name) = @as(*const f.type, @ptrCast(@alignCast(ptr))).*;
            } else {
                return error.MissingField;
            }
        }

        return res;
    }

    /// Reads the request body as JSON.
    pub fn readJson(self: *Context, comptime T: type) !T {
        const body = self.req.body() orelse return error.BadRequest;

        return std.json.parseFromSliceLeaky(T, self.req.arena, body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
            error.InvalidCharacter, error.UnexpectedToken, error.InvalidNumber, error.Overflow, error.InvalidEnumTag, error.DuplicateField, error.UnknownField, error.MissingField, error.LengthMismatch => error.BadRequest,
            else => e,
        };
    }

    /// Returns the value of the given cookie or null if it doesn't exist.
    pub fn getCookie(self: *Context, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, self.req.header("cookie") orelse "", "; ");

        while (it.next()) |part| {
            const i = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const key = part[0..i];
            const value = part[i + 1 ..];

            if (std.mem.eql(u8, key, name)) return value;
        }

        return null;
    }

    /// Sets a cookie.
    pub fn setCookie(self: *Context, name: []const u8, value: []const u8, options: CookieOptions) !void {
        // TODO: start with current header?
        var buf = std.ArrayList(u8).init(self.req.arena);
        const writer = buf.writer();

        try writer.print("{s}={s}", .{ name, value });

        if (options.max_age) |age| try writer.print("; Max-Age={d}", .{age});
        if (options.domain) |domain| try writer.print("; Domain={s}", .{domain});
        if (options.http_only) try writer.writeAll("; HttpOnly");
        if (options.secure) try writer.writeAll("; Secure");

        self.res.header("set-cookie", buf.items);
    }

    pub fn send(self: *Context, res: anytype) !void {
        self.responded = true;

        if (comptime std.meta.hasMethod(@TypeOf(res), "sendResponse")) {
            return res.sendResponse(self);
        }

        return switch (@TypeOf(res)) {
            []const u8 => {
                if (self.res.content_type == null) self.res.content_type = .TEXT;
                self.res.body = res;
            },
            else => |T| switch (@typeInfo(T)) {
                .void => return,
                .error_set => {
                    self.res.status = getErrorStatus(res);
                    try self.send(.{ .@"error" = res });
                },
                .error_union => if (res) |r| self.send(r) else |e| self.send(e),
                else => self.res.json(res, .{}),
            },
        };
    }

    /// Redirects the client to a different URL with an optional status code.
    pub fn redirect(self: *Context, url: []const u8, options: struct { status: u16 = 302 }) !void {
        self.responded = true;
        self.res.status = options.status;
        self.res.header("location", url);
    }

    pub fn next(self: *Context) !void {
        for (self.current.children) |route| {
            if (route.match(self.req)) |params| {
                self.current = route;
                self.params = params;

                if (route.handler) |handler| {
                    try handler(self);
                } else {
                    try self.next();
                }
            }

            if (self.responded) return;
        }
    }

    pub fn nextScoped(self: *Context, ctx: anytype) !void {
        const prev = self.injector;
        defer self.injector = prev;
        self.injector = Injector.init(ctx, &prev);

        try self.next();
    }
};

/// Wrapper type over already-initialized iterator, which will be cloned with
/// meta.dupe() and then run in a newly created thread. Every next() result
/// will be JSON stringified and sent as SSE event.
pub fn EventStream(comptime T: type) type {
    const Cx = struct { *std.heap.ArenaAllocator, T };

    return struct {
        impl: T,

        pub const jsonSchema: Schema = Schema.forType(meta.Result(T.next));

        pub fn sendResponse(self: @This(), ctx: *Context) !void {
            const allocator = ctx.server.allocator;

            const arena = try allocator.create(std.heap.ArenaAllocator);
            errdefer allocator.destroy(arena);

            arena.* = .init(allocator);
            errdefer arena.deinit();

            const clone = try meta.dupe(arena.allocator(), self.impl);
            try ctx.res.startEventStream(Cx{ arena, clone }, run);
        }

        fn run(cx: Cx, stream: std.net.Stream) void {
            const arena, var impl = cx;

            defer {
                if (comptime std.meta.hasMethod(T, "deinit")) {
                    impl.deinit();
                }

                stream.close();
                arena.deinit();
                arena.child_allocator.destroy(arena);
            }

            while (impl.next()) |ev| {
                sendEvent(stream, ev orelse break) catch break;
            } else |e| {
                sendEvent(stream, .{ .@"error" = @errorName(e) }) catch {};
            }
        }

        fn sendEvent(stream: std.net.Stream, event: anytype) !void {
            try stream.writeAll("data: ");
            try std.json.stringify(event, .{}, stream.writer());
            try stream.writeAll("\n\n");
        }
    };
}

pub const CookieOptions = struct {
    domain: ?[]const u8 = null,
    max_age: ?u32 = null,
    http_only: bool = false,
    secure: bool = false,
};

pub fn getErrorStatus(e: anyerror) u16 {
    return switch (e) {
        error.BadRequest => 400,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound => 404,
        else => 500,
    };
}

// fn fakeReq(arena: *std.heap.ArenaAllocator, input: []const u8) !Request {
//     const bytes = try arena.allocator().dupe(u8, input);

//     var server: std.http.Server = undefined;
//     server.read_buffer = bytes;

//     return Request.init(
//         arena.allocator(),
//         std.http.Server.Request{
//             .server = &server,
//             .head = try std.http.Server.Request.Head.parse(bytes),
//             .head_end = bytes.len,
//             .reader_state = undefined,
//         },
//     );
// }

// test "request parsing" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();

//     const req1 = try fakeReq(&arena, "GET /test HTTP/1.0\r\n\r\n");
//     const req2 = try fakeReq(&arena, "POST /foo%20bar HTTP/1.0\r\n\r\n");
//     const req3 = try fakeReq(&arena, "PUT /foo%3Abar+baz HTTP/1.0\r\n\r\n");
//     const req4 = try fakeReq(&arena, "DELETE /test?foo=hello%20world&bar=baz%3Aqux&opt=null HTTP/1.0\r\n\r\n");

//     try std.testing.expectEqual(std.http.Method.GET, req1.method);
//     try std.testing.expectEqual(std.http.Method.POST, req2.method);
//     try std.testing.expectEqual(std.http.Method.PUT, req3.method);
//     try std.testing.expectEqual(std.http.Method.DELETE, req4.method);

//     try std.testing.expectEqualStrings("/test", req1.path);
//     try std.testing.expectEqualStrings("/foo bar", req2.path);
//     try std.testing.expectEqualStrings("/foo:bar baz", req3.path);
//     try std.testing.expectEqualStrings("/test", req4.path);

//     try std.testing.expectEqualStrings("hello world", req4.getQueryParam("foo").?);
//     try std.testing.expectEqualStrings("baz:qux", req4.getQueryParam("bar").?);
//     try std.testing.expectEqualStrings("null", req4.getQueryParam("opt").?);
//     try std.testing.expectEqual(null, req4.getQueryParam("missing"));
// }

// test "req.getCookie()" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();

//     var req = try fakeReq(&arena, "GET /test HTTP/1.0\r\nCookie: foo=bar; baz=qux\r\n\r\n");

//     try std.testing.expectEqualStrings("bar", req.getCookie("foo").?);
//     try std.testing.expectEqualStrings("qux", req.getCookie("baz").?);
//     try std.testing.expectEqual(null, req.getCookie("missing"));
// }

// test "req.readQuery()" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();

//     var req = try fakeReq(&arena, "GET /test?str=foo&num=123&opt=null HTTP/1.0\r\n\r\n");

//     const q1 = try req.readQuery(struct { str: []const u8, num: u32, opt: ?u32 });
//     try std.testing.expectEqualStrings("foo", q1.str);
//     try std.testing.expectEqual(123, q1.num);
//     try std.testing.expectEqual(null, q1.opt);

//     const q2 = try req.readQuery(struct { missing: ?u32 = null, opt: ?u32 });
//     try std.testing.expectEqual(null, q2.missing);
//     try std.testing.expectEqual(null, q2.opt);

//     const q3 = try req.readQuery(struct { num: u32 = 0, missing: u32 = 123 });
//     try std.testing.expectEqual(123, q3.num);
//     try std.testing.expectEqual(123, q3.missing);
// }
