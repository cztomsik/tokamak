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

    pub fn configure(bundle: *tk.Bundle) void {
        // Register some callbacks to be auto-called during the app init.
        bundle.addInitHook(initDb);
        bundle.addInitHook(printServerPort);
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

        try db.exec(
            \\ INSERT INTO todos (title, is_done) VALUES 
            \\ ('Learn Zig', 0), 
            \\ ('Build a Tokamak app', 0), 
            \\ ('Master SQLite', 1);
        , .{});

        // TODO: see server.zig for a matching TODO
        // NOTE: curl /todo was segfaulting when this was 120 (100 worked fine, so it has to be something related either to arena or some array building)
        // for (0..120) |_| {
        //     try db.exec("INSERT INTO todos (title, is_done) VALUES ('Fix arena segfault', 1);", .{});
        // }
    }

    fn printServerPort(server_opts: tk.ServerOptions) void {
        std.debug.print("Starting tokamak on: http://localhost:{d}/todo\n", .{server_opts.listen.port});
    }
};

pub fn main(init: std.process.Init) !void {
    try tk.app.run(init, tk.Server.start, &.{App});
}

fn readOne(db: *fr.Session, id: u32) !Todo {
    return try db.query(Todo).where("id", id).findOne() orelse error.NotFound;
}

fn readAll(db: *fr.Session) ![]const Todo {
    return try db.query(Todo).findAll();
}

fn create(res: *tk.Response, db: *fr.Session, data: Todo) !Todo {
    res.status = @intFromEnum(Status.created);
    return try db.query(Todo).insert(data).returning("*").fetchOne(Todo) orelse error.InternalServerError;
}

fn update(db: *fr.Session, id: u32, data: Todo) !void {
    return try db.update(Todo, id, data);
}

fn patch(db: *fr.Session, id: u32, data: PatchTodoReq) !void {
    var row = try db.query(Todo).where("id", id).findOne() orelse return error.NotFound;
    applyPatch(&row, data);
    return try db.update(Todo, id, row);
}

fn delete(db: *fr.Session, id: u32) !void {
    try db.query(Todo).where("id", id).delete().exec();
}

// helper for updating all fields which are set in the body and not null / undefined
fn applyPatch(dest: anytype, ptch: anytype) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(ptch))) |f| {
        if (@field(ptch, f)) |v| {
            @field(dest, f) = v;
        }
    }
}
