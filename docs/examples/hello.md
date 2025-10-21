# hello

The simplest example demonstrating a basic HTTP server with a single route.

## Source Code

**Path:** `examples/hello/`

```zig
const std = @import("std");
const tk = @import("tokamak");

const routes: []const tk.Route = &.{
    .get("/", hello),
};

fn hello() ![]const u8 {
    return "Hello, world!";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try tk.Server.init(gpa.allocator(), routes, .{});
    defer server.deinit();

    try server.start();
}
```

## Features Demonstrated

- Basic server setup
- Simple routing
- Handler functions
- Manual memory management with GeneralPurposeAllocator

## Running

```sh
cd examples/hello
zig build run
```

The server will start on the default port (8080). Visit http://localhost:8080/ to see the greeting.

## Next Steps

- See [hello_app](./hello_app.md) for a more streamlined version using the app framework
- Check out [blog](./blog.md) for a full REST API example
