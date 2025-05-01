# Todo example API

Uses [fridge](https://github.com/cztomsik/fridge) as ORM to persist the data with SQLite3.

Change `sqlite_filename` in [src/main.zig](./src/main.zig) from `:memory:` to e.g. `db.sqlite` to persist the database on disk.

```
const sqlite_filename = "db.sqlite";
```

## Run

```sh
zig build run
```

## Endpoints

### Create

`curl -X POST -H "content-type: application/json" -d '{ "title": "my todo" }' http://localhost:8080/todo`

```json
{ "id": 1 }
```

### Read one

`curl http://localhost:8080/todo/1`

```json
{ "id": 1, "title": "my todo", "is_done": false }
```

### Read all

`curl http://localhost:8080/todo`

```json
[{ "id": 1, "title": "my todo", "is_done": false }]
```

### Update one

`curl -X PUT -H "content-type: application/json" -d '{ "id": 1, "is_done": true, "title": "my todo" }' http://localhost:8080/todo/1`

### Patch one

`curl -X PATCH -H "content-type: application/json" -d '{ "title": "new title only" }' http://localhost:8080/todo/1`

```json
{ "id": 1, "title": "new title only", "is_done": true }
```

### Delete one

`curl -X DELETE http://localhost:8080/todo/1`
