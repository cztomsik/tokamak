# Server

HTTP server built on [http.zig](https://github.com/karlseguin/http.zig).

## Initialization

```zig
tk.Server.init(allocator: std.mem.Allocator, routes: []const Route, options: ServerOptions) !Server
```

Creates a server instance with the provided routes and configuration.

```zig
var server = try tk.Server.init(allocator, routes, .{
    .listen = .{ .port = 8080, .address = "127.0.0.1" },
    .injector = &injector,
});
defer server.deinit();
```

## ServerOptions

```zig
.listen = .{
    .port: u16,           // Default: 8080
    .address: []const u8, // Default: "127.0.0.1"
}
.injector: ?*Injector,    // Optional DI container
```

## Methods

### start()

```zig
server.start() !void
```

Starts the server and blocks. Never returns unless an error occurs.

### deinit()

```zig
server.deinit() void
```

Cleans up server resources.

## Static Files

### Single File

```zig
tk.static.file(path: []const u8) Route
```

Serves a single static file.

```zig
const routes = &.{
    .get("/", tk.static.file("public/index.html")),
};
```

### Directory

```zig
tk.static.dir(path: []const u8, options: DirOptions) Route
```

Serves a directory of static files.

```zig
const routes = &.{
    tk.static.dir("public", .{}),
};
```

**DirOptions:**
- `index: ?[]const u8` - Index file (default: "index.html")

### Embedded Files

Configure in `build.zig` to embed files into the binary:

```zig
tokamak.setup(exe, .{
    .embed = &.{
        "public/index.html",
        "assets/style.css",
    },
});
```

Embedded files are served from memory. Non-embedded files are read from the filesystem.

## MIME Types

Custom MIME types can be defined in the root module:

```zig
pub const mime_types = tk.mime_types ++ .{
    .{ ".foo", "text/foo" },
    .{ ".bar", "application/bar" },
};
```

## Multi-Module System

Using `tk.app.run()`:

```zig
const App = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{ /* ... */ },
};

pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{App});
}
```

The container automatically initializes the server and its dependencies.
