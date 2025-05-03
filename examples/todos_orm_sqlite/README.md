# Todo example API

Uses [fridge](https://github.com/cztomsik/fridge) as ORM to persist the data with SQLite3.

Change `App.db_opts.filename` in [src/main.zig](./src/main.zig) from `:memory:` to e.g. `db.sqlite` to persist the database on disk.

```zig
db_opts: fr.SQLite3.Options = .{ .filename = "db.sqlite" },
```

## Run

```sh
zig build run
```

## Endpoints

### Create

```sh
curl -X POST -H "content-type: application/json" \
-d '{ "title": "my todo" }' \
http://localhost:8080/todo
```

Status: 201

```json
{ "id": 1, "title": "my todo", "is_done": false }
```

### Read one

```sh
curl http://localhost:8080/todo/1
```

Status: 200

```json
{ "id": 1, "title": "my todo", "is_done": false }
```

### Read all

```sh
curl http://localhost:8080/todo
```

Status: 200

```json
[{ "id": 1, "title": "my todo", "is_done": false }]
```

### Update one

```sh
curl -X PUT -H "content-type: application/json" \
-d '{ "id": 1, "is_done": true, "title": "my todo" }' \
http://localhost:8080/todo/1
```

Status: 204

### Patch one

```sh
curl -X PATCH -H "content-type: application/json" \
-d '{ "title": "new title only" }' \
http://localhost:8080/todo/1
```

Status: 204

### Delete one

```
curl -X DELETE http://localhost:8080/todo/1
```

Status: 204
