const std = @import("std");
const Context = @import("server.zig").Context;
const Handler = @import("server.zig").Handler;

/// Returns a middleware that executes given steps as a chain. Every step should
/// either respond or call the next step in the chain.
pub fn chain(comptime steps: anytype) Handler {
    const H = struct {
        fn handleChain(ctx: *Context) anyerror!void {
            try ctx.stack.appendSlice(comptime brk: {
                var res: [steps.len]*const Handler = undefined;
                for (steps, 0..) |m, i| res[steps.len - i - 1] = Context.wrap(m);
                break :brk &res;
            });

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

                try Context.wrap(handler)(ctx);

                if (ctx.res.responded) {
                    return;
                }
            }

            return ctx.next();
        }
    };
    return H.handleGroup;
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
