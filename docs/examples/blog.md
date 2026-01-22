# blog

A REST API example with Swagger UI documentation and static file serving.

## Source Code

**Path:** `examples/blog/`

```zig
@include examples/blog/src/main.zig
```

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
@include examples/blog/src/main.zig#L6-L17
```

### Service Layer

The `BlogService` manages blog posts in memory:

```zig
@include examples/blog/src/model.zig#L9-L70
```

### API Layer

The API layer (`api.zig`) defines route handlers that delegate to the service:

```zig
@include examples/blog/src/api.zig#L9-L15
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

### Route Grouping, Middleware, and Router

The main application shows all these patterns together:

```zig
@include examples/blog/src/main.zig#L9-L16
```

- `.group("/api", ...)` groups all API routes under `/api` prefix
- `tk.logger(.{}, ...)` wraps routes with logging middleware
- `.router(api)` automatically creates routes from all public functions in the `api` module using the `@"METHOD /path"` naming convention

## Next Steps

- See [todos_orm_sqlite](./todos_orm_sqlite.md) for database persistence
- Check out the [Middlewares guide](/guide/middlewares) for more middleware options
