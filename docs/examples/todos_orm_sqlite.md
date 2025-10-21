# todos_orm_sqlite

A complete REST API using SQLite database with ORM integration.

## Source Code

**Path:** `examples/todos_orm_sqlite/`

## Features Demonstrated

- Database integration with [fridge ORM](https://github.com/cztomsik/fridge)
- Connection pooling
- Database migrations
- CRUD operations with SQL
- PATCH endpoint with partial updates
- Lifecycle hooks (`configure`, `initDb`)
- Custom middleware composition

## Model

```zig
const Todo = struct {
    pub const sql_table_name = "todos";
    id: ?u32 = null,
    title: []const u8,
    is_done: bool = false,
};
```

## Database Setup

The app uses lifecycle hooks to initialize the database:

```zig
const App = struct {
    db_pool: fr.Pool(fr.SQLite3),
    db_opts: fr.SQLite3.Options = .{ .filename = ":memory:" },
    db_pool_opts: fr.PoolOptions = .{ .max_count = 4 },

    pub fn configure(bundle: *tk.Bundle) void {
        bundle.addInitHook(initDb);
    }

    fn initDb(allocator: std.mem.Allocator, db_pool: *fr.Pool(fr.SQLite3)) !void {
        var db = try db_pool.getSession(allocator);
        defer db.deinit();

        try db.exec(
            \\ CREATE TABLE IF NOT EXISTS todos (
            \\   id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\   title TEXT NOT NULL,
            \\   is_done BOOLEAN NOT NULL
            \\ );
        , .{});
    }
};
```

## API Endpoints

### Create Todo
```sh
curl -X POST -H "content-type: application/json" \
  -d '{ "title": "my todo" }' \
  http://localhost:8080/todo
```
**Status:** 201 Created
```json
{ "id": 1, "title": "my todo", "is_done": false }
```

### List All Todos
```sh
curl http://localhost:8080/todo
```
**Status:** 200 OK
```json
[{ "id": 1, "title": "my todo", "is_done": false }]
```

### Get Single Todo
```sh
curl http://localhost:8080/todo/1
```
**Status:** 200 OK
```json
{ "id": 1, "title": "my todo", "is_done": false }
```

### Update Todo (Full Replacement)
```sh
curl -X PUT -H "content-type: application/json" \
  -d '{ "id": 1, "is_done": true, "title": "my todo" }' \
  http://localhost:8080/todo/1
```
**Status:** 204 No Content

### Patch Todo (Partial Update)
```sh
curl -X PATCH -H "content-type: application/json" \
  -d '{ "title": "new title only" }' \
  http://localhost:8080/todo/1
```
**Status:** 204 No Content

Only the fields provided are updated. This example includes a helper function `patchSetFields` that handles partial updates generically.

### Delete Todo
```sh
curl -X DELETE http://localhost:8080/todo/1
```
**Status:** 204 No Content

## Handler Examples

### Create with Custom Status
```zig
fn create(res: *tk.Response, db: *fr.Session, body: Todo) !Todo {
    res.status = @intFromEnum(Status.created);
    return try db.query(Todo)
        .insert(body)
        .returning("*")
        .fetchOne(Todo) orelse error.InternalServerError;
}
```

### Read with ORM
```zig
fn readOne(db: *fr.Session, id: u32) !Todo {
    return try db.query(Todo).find(id) orelse error.NotFound;
}

fn readAll(db: *fr.Session) ![]const Todo {
    return try db.query(Todo).findAll();
}
```

### Delete with Query Builder
```zig
fn delete(db: *fr.Session, id: u32) !void {
    try db.query(Todo).where("id", id).delete().exec();
}
```

## Configuration

### In-Memory Database (Default)
```zig
db_opts: fr.SQLite3.Options = .{ .filename = ":memory:" },
```

### Persistent Database
```zig
db_opts: fr.SQLite3.Options = .{ .filename = "db.sqlite" },
```

### Connection Pool
```zig
db_pool_opts: fr.PoolOptions = .{ .max_count = 4 },
```

## Running

```sh
cd examples/todos_orm_sqlite
zig build run
```

The server starts at http://localhost:8080/todo

## Dependency Injection Pattern

Database sessions are provided to handlers via middleware:

```zig
.provide(fr.Pool(fr.SQLite3).getSession, &.{
    .group("/todo", &.{
        .get("/", readAll),
        .post("/", create),
        // ...
    })
})
```

Handlers simply request `db: *fr.Session` and get an active session.

## Next Steps

- See the [fridge ORM documentation](https://github.com/cztomsik/fridge) for more query capabilities
- Check out [blog](./blog.md) for service layer patterns
- Read the [Dependency Injection guide](/guide/dependency-injection) for more on DI patterns
