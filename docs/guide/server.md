# Server

The `tk.Server` is the core component that handles HTTP requests and manages the application lifecycle.

## Basic Setup

Creating a server is straightforward:

```zig
var server = try tk.Server.init(allocator, routes, .{
    .listen = .{ .port = 8080 }
});
try server.start();
```

## Configuration Options

The server accepts several configuration options:

```zig
var server = try tk.Server.init(allocator, routes, .{
    .listen = .{
        .port = 8080,
        .address = "127.0.0.1",
    },
    .injector = &custom_injector, // Optional: custom DI container
});
```

## Custom Dependencies

You can provide global dependencies to your handlers:

```zig
pub fn main() !void {
    var db = try sqlite.open("my.db");
    var inj = tk.Injector.init(&.{ .ref(&db) }, null);

    var server = try tk.Server.init(allocator, routes, .{
        .injector = &inj,
        .listen = .{ .port = 8080 }
    });

    try server.start();
}
```

Now any handler can inject the database:

```zig
fn getUser(db: *sqlite.Database, name: []const u8) !User {
    return db.query(User, "SELECT * FROM users WHERE name = ?", .{name});
}
```

## Process Monitoring

The `tk.monitor()` function runs multiple processes in parallel with automatic restart on crashes:

```zig
tk.monitor(.{
    .{ "server", &runServer, .{ 8080 } },
    .{ "worker", &runWorker, .{} },
});
```

::: warning
Process monitoring requires `fork()` support and takes over the main thread. Use with caution.
:::

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
