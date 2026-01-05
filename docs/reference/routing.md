# Routing

Express-inspired router with path parameters, wildcards, and nested routes.

## Route Definition

```zig
const routes: []const tk.Route = &.{
    .get(path, handler),
    .post(path, handler),
    .put(path, handler),
    .delete(path, handler),
    .patch(path, handler),
};
```

Body-less variants (skip JSON parsing):
```zig
.post0(path, handler)
.put0(path, handler)
.patch0(path, handler)
```

## Path Parameters

Syntax: `/:param`

Maximum: 16 parameters per route.

```zig
.get("/users/:id", handler)
.get("/users/:userId/posts/:postId", handler)
```

Parameters are passed as function arguments after dependencies:

```zig
fn handler(db: *Database, userId: []const u8, postId: []const u8) !Post {
    return db.getPost(userId, postId);
}
```

## Wildcards

Syntax: `*`

```zig
.get("/assets/*", handler)
.get("/api/*", handler)
```

## Grouping

```zig
.group(prefix, routes)
```

Groups routes under a common prefix:

```zig
const routes = &.{
    .group("/api", &.{
        .get("/users", getUsers),
        .post("/users", createUser),
    }),
};
```

## Router DSL

```zig
.router(T)
```

Creates routes from a struct's public functions. Function names define method and path:

```zig
const api = struct {
    pub fn @"GET /"() []const u8 { ... }
    pub fn @"GET /:id"(id: u32) !User { ... }
    pub fn @"POST /"(body: User) !User { ... }
    pub fn @"PUT /:id"(id: u32, body: User) !void { ... }
    pub fn @"DELETE /:id"(id: u32) !void { ... }
};

const routes = &.{ .router(api) };
```

## Scoped Dependencies

```zig
.provide(fn, routes)
```

Inject dependencies to nested routes (middleware pattern):

```zig
const routes = &.{
    .provide(authenticate, &.{
        .get("/profile", getProfile),
        .post("/logout", logout),
    }),
};

fn authenticate(req: *tk.Request) !*User {
    const token = req.header("Authorization") orelse return error.Unauthorized;
    return try validateToken(token);
}

fn getProfile(user: *User) !UserProfile {
    return .{
        .id = user.id,
        .name = user.name,
        .email = user.email,
    };
}
```

The `user` dependency is automatically available to nested route handlers.

## Route Helpers

### Static Responses

```zig
tk.Route.send(value)
```

Send a compile-time constant response:

```zig
const routes = &.{
    .get("/health", tk.Route.send(.{ .status = "ok" })),
    .get("/version", tk.Route.send("1.0.0")),
};
```

### Redirects

```zig
tk.Route.redirect(url)
```

Redirect to another URL:

```zig
const routes = &.{
    .get("/old-path", tk.Route.redirect("/new-path")),
    .get("/home", tk.Route.redirect("/")),
};
```

## Request Body Parsing

Routes with bodies (`.post()`, `.put()`, `.patch()`) automatically parse JSON into the `body` parameter:

```zig
fn createUser(body: User) !User {
    // body is deserialized from request JSON
}
```

Manual body reading (use body-less variants):

```zig
fn handleWebhook(req: *tk.Request) !void {
    const body = try req.readAll();
}
```

## Handler Signatures

Handlers can request any injectable dependencies plus path parameters:

```zig
// No dependencies, no parameters
fn index() []const u8

// With dependencies
fn getUser(db: *Database, cache: *Cache, id: []const u8) !User

// With allocator and parameters
fn hello(arena: std.mem.Allocator, name: []const u8) ![]const u8

// With request body
fn createUser(db: *Database, body: User) !User
```

## Middleware

Middleware is implemented as functions that wrap child routes:

```zig
fn logger(children: []const tk.Route) tk.Route {
    const H = struct {
        fn handle(ctx: *tk.Context) !void {
            log.info("{s} {s}", .{@tagName(ctx.req.method), ctx.req.url});
            return ctx.next();
        }
    };
    return .{ .handler = &H.handle, .children = children };
}

const routes = &.{
    logger(&.{
        .get("/", index),
    }),
};
```

## Swagger/OpenAPI

```zig
tk.swagger.json(options) Route
tk.swagger.ui(options) Route
```

Generates OpenAPI specification and Swagger UI:

```zig
const routes = &.{
    .get("/openapi.json", tk.swagger.json(.{ .info = .{ .title = "My API" } })),
    .get("/swagger-ui", tk.swagger.ui(.{ .url = "openapi.json" })),
};
```
