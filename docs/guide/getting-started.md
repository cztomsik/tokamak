# Getting Started

Tokamak is a server-side framework for Zig, built around [http.zig](https://github.com/karlseguin/http.zig) and a simple dependency injection container.

::: warning
Tokamak is **not designed to be used alone**. Use it with a reverse proxy like Nginx or Cloudfront to handle SSL, caching, and sanitization.
:::

## Installation

Add Tokamak to your project using Zig's package manager:

```bash
zig fetch --save "git+https://github.com/cztomsik/tokamak#main"
```

Then in your `build.zig`:

```zig
const tokamak = @import("tokamak");

pub fn build(b: *std.Build) void {
    // ...
    const exe = b.addExecutable(.{ /* ... */ });
    // ...

    // Add tokamak
    tokamak.setup(exe, .{});
}
```

## Hello World

Here's a minimal example to get you started:

```zig
const std = @import("std");
const tk = @import("tokamak");

const routes: []const tk.Route = &.{
    .get("/", hello),
};

fn hello() ![]const u8 {
    return "Hello";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try tk.Server.init(allocator, routes, .{
        .listen = .{ .port = 8080 }
    });
    try server.start();
}
```

That's it! Your server is now running on port 8080.

## What's Next?

- Learn about the [Server](/guide/server) setup and configuration
- Explore [Routing](/guide/routing) patterns
- Understand [Dependency Injection](/guide/dependency-injection)
- Implement [Middlewares](/guide/middlewares) for cross-cutting concerns
