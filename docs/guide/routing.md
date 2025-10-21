# Routing

Tokamak includes an Express-inspired router with support for path parameters, wildcards, and nested routes.

## Basic Routes

Define routes with HTTP method shortcuts:

```zig
const routes: []const tk.Route = &.{
    .get("/", hello),
    .post("/users", createUser),
    .put("/users/:id", updateUser),
    .delete("/users/:id", deleteUser),
};
```

## Path Parameters

Path parameters are automatically extracted and passed to handlers:

```zig
const routes: []const tk.Route = &.{
    .get("/hello/:name", helloName),
    .get("/users/:id/posts/:postId", getUserPost),
};

fn helloName(name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Hello {s}", .{name});
}

fn getUserPost(id: []const u8, postId: []const u8) !Post {
    // id and postId are automatically injected
    return db.getPost(id, postId);
}
```

::: tip
Tokamak supports up to 16 path parameters per route.
:::

## Wildcards

Use `*` for wildcard matching:

```zig
const routes: []const tk.Route = &.{
    .get("/api/*", apiHandler),
    .get("/assets/*", tk.static.dir("assets", .{})),
};
```

## Nested Routes

Group routes with common prefixes:

```zig
const routes: []const tk.Route = &.{
    .group("/api", &.{
        .group("/v1", &.{
            .get("/users", getUsers),
            .post("/users", createUser),
        }),
        .group("/v2", &.{
            .get("/users", getUsersV2),
        }),
    }),
};
```

## Router DSL

For more organized routing, use `Route.router(T)` with a struct:

```zig
const routes: []const tk.Route = &.{
    .group("/api", &.{ .router(api) }),
};

const api = struct {
    pub fn @"GET /"() []const u8 {
        return "API Home";
    }

    pub fn @"GET /:name"(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "Hello {s}", .{name});
    }

    pub fn @"POST /users"(body: User) !User {
        // body is automatically parsed from JSON
        return db.create(body);
    }
};
```

## Request Body

POST/PUT routes automatically parse JSON bodies:

```zig
fn createUser(body: User) !User {
    // body is automatically deserialized
    return db.save(body);
}
```

Use `.post0()` to skip body parsing:

```zig
const routes: []const tk.Route = &.{
    .post0("/webhook", handleWebhook),
};

fn handleWebhook(req: *tk.Request) !void {
    // Manually read the body
    const body = try req.readAll();
}
```

## Route Inspection

Routes are hierarchical and introspectable, making it easy to generate documentation or OpenAPI specs:

```zig
// Tokamak includes basic Swagger support
const routes: []const tk.Route = &.{
    tk.swagger(.{}),
    .get("/users", getUsers),
};
```
