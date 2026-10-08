# Server

The `tk.Server` handles HTTP requests and manages the application lifecycle. It uses dusty by default or httpz when selected in `build.zig`.

## Backend Selection

The build selects one HTTP backend for the application.

For dusty (the default):

```zig
tokamak.setup(exe, .{});
```

For httpz (http.zig), use this instead:

```zig
tokamak.setup(exe, .{ .backend = .httpz });
```

Only the selected backend is fetched. Both expose the same `tk.Request`,
`tk.Response`, routing, and middleware APIs. `examples/hello` uses dusty;
`examples/hello_app` uses httpz. To run the framework tests against both
backends, use `zig build test` and `zig build test -Dbackend=httpz` from the
repository root.

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
`max_connections` and `trusted_proxy_hops` options apply only to dusty; httpz
ignores them. `server.port()` returns the bound port after startup, including
when the configured port is `0`.

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
