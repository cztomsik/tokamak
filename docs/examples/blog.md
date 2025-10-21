# blog

A REST API example with Swagger UI documentation and static file serving.

## Source Code

**Path:** `examples/blog/`

## Features Demonstrated

- REST API with CRUD operations
- Service layer architecture (`BlogService`)
- OpenAPI/Swagger integration
- Static file serving
- Route grouping and middleware
- Logger middleware

## Architecture

### Main Application

```zig
const App = struct {
    blog_service: model.BlogService,
    server: tk.Server,
    routes: []const tk.Route = &.{
        tk.logger(.{}, &.{
            tk.static.dir("public", .{}),
            .group("/api", &.{.router(api)}),
            .get("/openapi.json", tk.swagger.json(.{ .info = .{ .title = "Example" } })),
            .get("/swagger-ui", tk.swagger.ui(.{ .url = "openapi.json" })),
        }),
    },
};
```

### Service Layer

The `BlogService` manages blog posts in memory:

```zig
pub const BlogService = struct {
    posts: std.AutoArrayHashMap(u32, Post),
    next: std.atomic.Value(u32) = .init(1),

    pub fn getPosts(self: *BlogService, allocator: std.mem.Allocator) ![]const Post
    pub fn createPost(self: *BlogService, data: Post) !u32
    pub fn getPost(self: *BlogService, allocator: std.mem.Allocator, id: u32) !Post
    pub fn updatePost(self: *BlogService, id: u32, data: Post) !void
    pub fn deletePost(self: *BlogService, id: u32) !void
};
```

### API Layer

The API layer (`api.zig`) defines route handlers that delegate to the service:

```zig
pub fn @"GET /posts"(svc: *BlogService, allocator: std.mem.Allocator) ![]const Post {
    return svc.getPosts(allocator);
}

pub fn @"POST /posts"(svc: *BlogService, data: Post) !u32 {
    return svc.createPost(data);
}
```

Note the special syntax: function names starting with `@"GET /posts"` define both the HTTP method and path.

## API Endpoints

### List All Posts
```sh
GET /api/posts
```

### Get Single Post
```sh
GET /api/posts/:id
```

### Create Post
```sh
POST /api/posts
Content-Type: application/json

{
  "id": 0,
  "title": "My Post",
  "body": "Content here"
}
```

### Update Post
```sh
PUT /api/posts/:id
Content-Type: application/json

{
  "id": 1,
  "title": "Updated Title",
  "body": "Updated content"
}
```

### Delete Post
```sh
DELETE /api/posts/:id
```

## Swagger UI

Visit http://localhost:8080/swagger-ui for interactive API documentation where you can:
- Browse all endpoints
- See request/response schemas
- Try out the API directly in your browser

## Running

```sh
cd examples/blog
zig build run
```

Then open:
- http://localhost:8080/ - Static frontend
- http://localhost:8080/swagger-ui - API documentation
- http://localhost:8080/openapi.json - OpenAPI spec

## Key Patterns

### Route Grouping
```zig
.group("/api", &.{.router(api)})
```
Groups all API routes under `/api` prefix.

### Middleware Composition
```zig
tk.logger(.{}, &.{
    // routes...
})
```
Wraps routes with logging middleware.

### Router from Functions
```zig
.router(api)
```
Automatically creates routes from all public functions in the `api` module using the `@"METHOD /path"` naming convention.

## Next Steps

- See [todos_orm_sqlite](./todos_orm_sqlite.md) for database persistence
- Check out the [Middlewares guide](/guide/middlewares) for more middleware options
