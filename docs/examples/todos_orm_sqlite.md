# todos_orm_sqlite

A complete REST API using SQLite database with ORM integration.

## Source Code

**Path:** `examples/todos_orm_sqlite/`

```zig
@include examples/todos_orm_sqlite/src/main.zig
```

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
@include examples/todos_orm_sqlite/src/main.zig#L6-L11
```

## Database Setup

The app uses lifecycle hooks to initialize the database:

```zig
@include examples/todos_orm_sqlite/src/main.zig#L18-L61
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
@include examples/todos_orm_sqlite/src/main.zig#L75-L78
```

### Read with ORM
```zig
@include examples/todos_orm_sqlite/src/main.zig#L67-L73
```

### Delete with Query Builder
```zig
@include examples/todos_orm_sqlite/src/main.zig#L88-L90
```

## Configuration

Database and connection pool options are configured in the App struct:

```zig
@include examples/todos_orm_sqlite/src/main.zig#L19-L21
```

- Change `filename` to a path like `"db.sqlite"` for persistence
- Adjust `max_count` for connection pool size

## Running

```sh
cd examples/todos_orm_sqlite
zig build run
```

The server starts at http://localhost:8080/todo

## Dependency Injection Pattern

Database sessions are provided to handlers via middleware:

```zig
@include examples/todos_orm_sqlite/src/main.zig#L24-L37
```

Handlers simply request `db: *fr.Session` and get an active session.

## Next Steps

- See the [fridge ORM documentation](https://github.com/cztomsik/fridge) for more query capabilities
- Check out [blog](./blog.md) for service layer patterns
- Read the [Dependency Injection guide](../guide/dependency-injection.md) for more on DI patterns
