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
    .head(path, handler),
    .options(path, handler),
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

```zig
.handler(fn)
```

Middleware receives `*Context` and must call `ctx.next()`:

```zig
fn logger(ctx: *tk.Context) !void {
    log.info("{s} {s}", .{@tagName(ctx.req.method), ctx.req.url});
    return ctx.next();
}

const routes = &.{
    .handler(logger),
    .get("/", index),
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
