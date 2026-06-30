const std = @import("std");
const httpz = @import("httpz");
const meta = @import("meta.zig");
const serde = @import("serde.zig");
const Injector = @import("injector.zig").Injector;
const Server = @import("server.zig").Server;
const Route = @import("route.zig").Route;
const Params = @import("route.zig").Params;
const Schema = @import("schema.zig").Schema;
const parseValue = @import("parse.zig").parseValue;
const log = std.log.scoped(.tokamak);

/// Function signature for route handlers.
pub const Handler = fn (*Context) anyerror!void;

/// Function signature for custom error handlers.
pub const ErrorHandler = fn (*Context, err: anyerror) anyerror!void;

/// Request context for middleware and advanced handlers. Note that most route
/// handlers should inject dependencies directly (e.g., `*tk.Request`,
/// `*tk.Response`) instead.
pub const Context = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
    current: Route,
    params: Params,
    injector: *Injector,
    responded: bool = false,
    error_handler: ?*const ErrorHandler = null,

    /// Parse a string value into the requested type.
    pub fn parse(self: *Context, comptime T: type, s: []const u8) !T {
        return parseValue(T, s, self.req.arena);
    }

    /// Reads the query parameters into a struct.
    pub fn readQuery(self: *Context, comptime T: type) !T {
        const query = try self.req.query();
        var res: T = undefined;

        const s = @typeInfo(T).@"struct";
        inline for (s.field_names, s.field_types, s.field_attrs) |f, ft, fa| {
            if (query.get(f)) |param| {
                @field(res, f) = try self.parse(ft, param);
            } else if (fa.defaultValue(ft)) |def| {
                @field(res, f) = def;
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
        var bw: std.Io.Writer.Allocating = .init(self.req.arena);
        const w = &bw.writer;

        try w.print("{s}={s}", .{ name, value });

        if (options.max_age) |age| try w.print("; Max-Age={d}", .{age});
        if (options.domain) |domain| try w.print("; Domain={s}", .{domain});
        if (options.http_only) try w.writeAll("; HttpOnly");
        if (options.secure) try w.writeAll("; Secure");

        self.res.header("set-cookie", bw.written());
    }

    /// Send a response. Accepts strings, JSON-serializable values, errors, or
    /// types with a custom `sendResponse` method (like `EventStream`).
    pub fn send(self: *Context, res: anytype) !void {
        self.responded = true;

        if (std.meta.hasMethod(@TypeOf(res), "sendResponse")) {
            return res.sendResponse(self);
        }

        switch (@TypeOf(res)) {
            void => {
                // NOTE: redirect() sets 302 and such handlers are often void so we need to be explicit
                if (self.res.status == 200 and self.res.body.len == 0) {
                    self.res.status = 204;
                }
            },
            std.http.Status => {
                self.res.status = @intFromEnum(res);
            },
            []const u8 => {
                if (self.res.content_type == null) self.res.content_type = .TEXT;
                self.res.body = res;
            },
            else => |T| {
                // Comptime string
                if (meta.isString(T)) {
                    return self.send(@as([]const u8, res));
                }

                switch (@typeInfo(T)) {
                    .error_set => {
                        if (self.error_handler) |handler| {
                            try handler(self, res);
                        } else {
                            self.res.status = getErrorStatus(res);
                            try self.send(.{ .@"error" = res });
                        }
                    },
                    .error_union => {
                        if (res) |r| {
                            try self.send(r);
                        } else |e| {
                            try self.send(e);
                        }
                    },
                    else => {
                        if (self.res.content_type == null) self.res.content_type = .JSON;
                        var jw = serde.json.Writer.init(&self.res.buffer.writer, .{});
                        try serde.serialize(&jw, res);
                    },
                }
            },
        }
    }

    /// Redirects the client to a different URL with an optional status code.
    pub fn redirect(self: *Context, url: []const u8, options: struct { status: u16 = 302 }) !void {
        self.responded = true;
        self.res.status = options.status;
        self.res.header("location", url);
    }

    /// Continue to the next matching route. Used by middleware to pass control.
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

    /// Continue with additional dependencies available for injection.
    pub fn nextScoped(self: *Context, inj: *Injector) !void {
        const curr = self.injector;
        defer self.injector = curr;

        self.injector = inj;
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
            var sw = stream.writer(&.{});
            const writer = &sw.interface;

            try writer.writeAll("data: ");
            try std.json.fmt(event, .{}).format(writer);
            try writer.writeAll("\n\n");
        }
    };
}

/// Options for `Context.setCookie()`.
pub const CookieOptions = struct {
    domain: ?[]const u8 = null,
    max_age: ?u32 = null,
    http_only: bool = false,
    secure: bool = false,
};

/// Map well-known errors to HTTP status codes. Returns 500 for unknown errors.
pub fn getErrorStatus(e: anyerror) u16 {
    return switch (e) {
        error.BadRequest => 400,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound => 404,
        else => 500,
    };
}
