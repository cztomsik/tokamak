# Getting Started

Welcome to Tokamak! This guide will help you build your first web application with Zig.

Tokamak is a server-side framework built around [http.zig](https://github.com/karlseguin/http.zig) and a simple but powerful dependency injection container. It's designed to make building web applications in Zig straightforward and enjoyable.

> **Warning:** Production Deployment
>
> Tokamak is designed to run behind a reverse proxy like Nginx or Cloudfront. The proxy should handle SSL termination, caching, and request sanitization.

## Installation

Getting started is easy! Add Tokamak to your project using Zig's package manager:

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

## Your First Server

Let's create a simple "Hello" server. Here's all the code you need:

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
    defer server.deinit();

    try server.start();
}
```

That's it! Build and run your application, then visit `http://localhost:8080` to see it in action.

## What's Next?

Now that you have a running server, let's explore what Tokamak can do:

- **[Server Setup](./server.md)** - Learn about configuration, static files, and server options
- **[Routing](./routing.md)** - Handle different paths, URL parameters, and HTTP methods
- **[Dependency Injection](./dependency-injection.md)** - Share services and configuration across your handlers
- **[Middlewares](./middlewares.md)** - Add logging, authentication, and other cross-cutting concerns

Ready to dive deeper? Let's start with the Server guide!
