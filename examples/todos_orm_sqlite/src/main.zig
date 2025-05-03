const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");
const Status = std.http.Status;

const Todo = struct {
    pub const sql_table_name = "todos";
    id: ?u32 = null,
    title: []const u8,
    is_done: bool = false,
};

pub const PatchTodoReq = struct {
    title: ?[]const u8 = null,
    is_done: ?bool = null,
};

const App = struct {
    db_pool: fr.Pool(fr.SQLite3),
    db_opts: fr.SQLite3.Options = .{ .filename = ":memory:" },
    db_pool_opts: fr.PoolOptions = .{ .max_count = 4 },
    server: tk.Server,
    server_opts: tk.ServerOptions = .{ .listen = .{ .port = 8080 } },
    routes: []const tk.Route = &.{
        // add debug logging
        tk.logger(.{}, &.{
            // provide the db session, group endpoints under /todo
            .provide(fr.Pool(fr.SQLite3).getSession, &.{.group("/todo", &.{
                .get("/", readAll),
                .get("/:id", readOne),
                .post("/", create),
                .put("/:id", update),
                .patch("/:id", patch),
                .delete("/:id", delete),
            })}),
        }),
    },

    pub fn afterAppInit(allocator: std.mem.Allocator, db_pool: *fr.Pool(fr.SQLite3), server: *tk.Server) !void {
        var db = try db_pool.getSession(allocator);
        defer db.deinit();

        try db.exec(
            \\ CREATE TABLE IF NOT EXISTS todos (
            \\   id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\   title TEXT NOT NULL,
            \\   is_done BOOLEAN NOT NULL
            \\ );
        , .{});

        std.debug.print("Starting tokamak on: http://localhost:{d}\n", .{server.http.config.port.?});
    }
};

pub fn main() !void {
    try tk.app.run(&.{App});
}

fn readOne(db: *fr.Session, id: u32) !Todo {
    return try db.query(Todo).find(id) orelse error.NotFound;
}

fn readAll(db: *fr.Session) ![]const Todo {
    return try db.query(Todo).findAll();
}

fn create(res: *tk.Response, db: *fr.Session, body: Todo) !Todo {
    res.status = @intFromEnum(Status.created);
    return try db.query(Todo).insert(body).returning("*").fetchOne(Todo) orelse error.InternalServerError;
}

fn update(db: *fr.Session, id: u32, body: Todo) !void {
    return try db.update(Todo, id, body);
}

fn patch(db: *fr.Session, id: u32, body: PatchTodoReq) !void {
    return try patchSetFields(db, Todo, PatchTodoReq, id, body);
}

fn delete(db: *fr.Session, id: u32) !void {
    try db.query(Todo).where("id", id).delete().exec();
}

// helper for updating all fields which are set in the body and not null / undefined
fn patchSetFields(db: *fr.Session, comptime RowType: type, comptime BodyType: type, id: u32, body: BodyType) !void {
    var row = try db.query(RowType).find(id) orelse return error.NotFound;

    inline for (
        std.meta.fields(BodyType),
    ) |field| {
        const body_field = @field(body, field.name);
        const is_set = if (switch (@typeInfo(field.type)) {
            .pointer => |ptr| ptr.size == .slice,
            else => false,
        }) {
            const Child = std.meta.Child(field.type);
            return !std.mem.eql(Child, body_field, null);
        } else body_field != null;

        // if the field is not null, update the row's field value
        if (is_set) {
            @field(row, field.name) = body_field.?;
        }
    }

    try db.update(RowType, id, row);
}
