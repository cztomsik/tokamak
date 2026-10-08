# Server

The `tk.Server` handles HTTP requests and manages the application lifecycle independently of the selected HTTP backend.

## Backend Selection

Choose a backend in `build.zig`. The default setup uses dusty:

```zig
tokamak.setup(exe, .{});
```

For httpz (http.zig), use this instead:

```zig
tokamak.setup(exe, .{ .backend = .httpz });
```

Only the selected backend is fetched. Routing, middleware, and the shared
`tk.Request` and `tk.Response` APIs are independent of the backend choice.
`examples/hello` and `examples/hello_app` demonstrate the two configurations.
Run `zig build test` for the default backend or `zig build test -Dbackend=httpz`
for httpz.

## Basic Setup

```zig
pub fn main(init: std.process.Init) !void {
    var server = try tk.Server.init(init.io, init.gpa, routes, .{
        .listen = .{ .port = 8080 },
    });
    defer server.deinit();

    try server.start();
}
```

## Configuration Options

The server accepts several configuration options:

```zig
var server = try tk.Server.init(init.io, init.gpa, routes, .{
    .listen = .{ .hostname = "127.0.0.1", .port = 8080 },
    .request = .{ .max_body_size = 1_048_576, .max_query_count = 32 },
    .timeout = .{ .request = .fromSeconds(30), .keepalive = .fromSeconds(60) },
    .injector = &custom_injector,
});
defer server.deinit();
```

`listen`, `request`, `timeout`, and `injector` apply to both backends. The
`max_connections` and `trusted_proxy_hops` options are backend-specific: only
dusty applies them; httpz ignores them. `server.port()` returns the bound port
after startup, including when the configured port is `0`.

## Custom Dependencies

You can provide global dependencies to your handlers:

```zig
pub fn main(init: std.process.Init) !void {
    var db = try sqlite.open("my.db");
    var inj = tk.Injector.init(&.{ .ref(&db) }, null);

    var server = try tk.Server.init(init.io, init.gpa, routes, .{
        .injector = &inj,
        .listen = .{ .port = 8080 },
    });
    defer server.deinit();

    try server.start();
}
```

Now any handler can inject the database:

```zig
fn getUser(db: *sqlite.Database, name: []const u8) !User {
    return db.query(User, "SELECT * FROM users WHERE name = ?", .{name});
}
```

## Static Files

Serve static files with built-in helpers:

```zig
const routes: []const tk.Route = &.{
    tk.static.dir("public", .{}),
};
```

For embedded files, configure them in `build.zig`:

```zig
tokamak.setup(exe, .{
    .embed = &.{
        "public/index.html",
    },
});
```
