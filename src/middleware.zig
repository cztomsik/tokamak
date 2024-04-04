const std = @import("std");
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;

/// Returns a middleware that executes given steps as a chain. Every step should
/// either respond or call the next step in the chain.
pub fn chain(comptime steps: anytype) Handler {
    const handlers = comptime brk: {
        var tmp: [steps.len]*const Handler = undefined;
        for (steps, 0..) |m, i| tmp[i] = &Context.wrap(m);
        const res = tmp;
        break :brk &res;
    };

    const H = struct {
        fn handleChain(ctx: *Context) anyerror!void {
            if (!try ctx.runScoped(handlers[0], handlers[1..])) {
                return;
            }

            // TODO: tail-call?
            return ctx.next();
        }
    };
    return H.handleChain;
}

/// Returns a middleware that matches the request path prefix and calls the
/// given handler/middleware. If the prefix matches, the request path is
/// modified to remove the prefix. If the handler/middleware responds, the
/// chain is stopped.
pub fn group(comptime prefix: []const u8, handler: anytype) Handler {
    const H = struct {
        fn handleGroup(ctx: *Context) anyerror!void {
            if (std.mem.startsWith(u8, ctx.req.url.path, prefix)) {
                const orig = ctx.req.url.path;
                ctx.req.url.path = ctx.req.url.path[prefix.len..];
                defer ctx.req.url.path = orig;

                if (!try ctx.runScoped(&Context.wrap(handler), &.{})) return;
            }

            // TODO: tail-call?
            return ctx.next();
        }
    };
    return H.handleGroup;
}

/// Returns a middleware for providing a dependency to the rest of the current
/// scope. Accepts a factory that returns the dependency. The factory can
/// use the current scope to resolve its own dependencies. If the resulting
/// type has a `deinit` method, it will be called at the end of the scope.
pub fn provide(comptime factory: anytype) Handler {
    const H = struct {
        fn handleProvide(ctx: *Context) anyerror!void {
            var dep = try ctx.injector.call(factory, .{});
            try ctx.injector.push(&dep);

            defer if (comptime hasDeinit(@TypeOf(dep))) {
                dep.deinit();
            };

            return ctx.next();
        }

        fn hasDeinit(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .Pointer => |ptr| hasDeinit(ptr.child),
                else => @hasDecl(T, "deinit"),
            };
        }
    };
    return H.handleProvide;
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

/// Returns a middleware for logging all requests going through it.
pub fn logger(options: struct { scope: @TypeOf(.EnumLiteral) = .server }) Handler {
    const log = std.log.scoped(options.scope);

    const H = struct {
        fn handleLogger(ctx: *Context) anyerror!void {
            const start = std.time.milliTimestamp();
            defer log.debug("{s} {s} {} [{}ms]", .{
                @tagName(ctx.req.method),
                ctx.req.raw.head.target,
                @intFromEnum(ctx.res.status),
                std.time.milliTimestamp() - start,
            });

            return ctx.next();
        }
    };
    return H.handleLogger;
}

/// Returns a middleware that sets the CORS headers for the request.
pub fn cors() Handler {
    const H = struct {
        fn handleCors(ctx: *Context) anyerror!void {
            try ctx.res.setHeader("Access-Control-Allow-Origin", ctx.req.getHeader("Origin") orelse "*");

            if (ctx.req.method == .OPTIONS) {
                try ctx.res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
                try ctx.res.setHeader("Access-Control-Allow-Headers", "Content-Type");
                try ctx.res.setHeader("Access-Control-Allow-Private-Network", "true");
                try ctx.res.noContent();
                return;
            }

            return ctx.next();
        }
    };
    return H.handleCors;
}
