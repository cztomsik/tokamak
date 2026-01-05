# Middlewares

While Tokamak doesn't have Express-style middleware, it achieves the same functionality through nested routes and context handlers.

## Basic Middleware

Create middleware by wrapping routes:

```zig
fn logger(children: []const tk.Route) tk.Route {
    const H = struct {
        fn handleLogger(ctx: *tk.Context) anyerror!void {
            log.debug("{s} {s}", .{
                @tagName(ctx.req.method),
                ctx.req.url
            });

            return ctx.next();
        }
    };

    return .{ .handler = &H.handleLogger, .children = children };
}

const routes: []const tk.Route = &.{
    logger(&.{
        .get("/", hello),
        .get("/users", getUsers),
    }),
};
```

## Context Handlers

Middleware handlers receive `*tk.Context` and must call `ctx.next()`:

```zig
fn timing(ctx: *tk.Context) anyerror!void {
    const start = std.time.milliTimestamp();

    try ctx.next();

    const duration = std.time.milliTimestamp() - start;
    log.info("Request took {}ms", .{duration});
}
```

## Request-Scoped Dependencies

Since Zig doesn't have closures, use `ctx.nextScoped()` to pass data to downstream handlers:

```zig
fn auth(ctx: *tk.Context) anyerror!void {
    const db = ctx.injector.get(*Database);
    const token = ctx.req.getHeader("Authorization") orelse
        return error.Unauthorized;

    const user = try jwt.parse(token);

    // Make user available to downstream handlers
    return ctx.nextScoped(&.{ user });
}

// Downstream handler can now inject User
fn getProfile(user: User) !Profile {
    return Profile{ .id = user.id, .name = user.name };
}
```

::: tip
Middleware handlers must use `ctx.injector.get(T)` to access dependencies manually, as they don't support automatic DI syntax.
:::

## Common Middleware Patterns

### Authentication

```zig
fn requireAuth(children: []const tk.Route) tk.Route {
    const H = struct {
        fn handle(ctx: *tk.Context) anyerror!void {
            const token = ctx.req.getHeader("Authorization") orelse
                return error.Unauthorized;

            const user = try validateToken(token);
            return ctx.nextScoped(&.{ user });
        }
    };

    return .{ .handler = &H.handle, .children = children };
}

const routes: []const tk.Route = &.{
    .get("/public", publicHandler),
    requireAuth(&.{
        .get("/private", privateHandler),
    }),
};
```

### CORS

```zig
fn cors(ctx: *tk.Context) anyerror!void {
    try ctx.res.setHeader("Access-Control-Allow-Origin", "*");
    try ctx.res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE");

    if (ctx.req.method == .OPTIONS) {
        try ctx.res.send("", .{});
        return;
    }

    try ctx.next();
}
```

### Error Handling

```zig
fn errorHandler(ctx: *tk.Context) anyerror!void {
    ctx.next() catch |err| {
        log.err("Request failed: {}", .{err});

        const status: u16 = switch (err) {
            error.Unauthorized => 401,
            error.NotFound => 404,
            error.ValidationError => 400,
            else => 500,
        };

        try ctx.res.status(status).json(.{
            .error = @errorName(err)
        }, .{});
    };
}
```

## Composing Middleware

Stack multiple middleware together:

```zig
const routes: []const tk.Route = &.{
    errorHandler(
        logger(
            cors(
                requireAuth(&.{
                    .get("/api/users", getUsers),
                })
            )
        )
    ),
};
```
