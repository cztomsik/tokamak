# tokamak

> I wrote a short blog post about the **[motivation and the design of the
> framework](https://tomsik.cz/posts/tokamak/)**
>
> I am doing some breaking changes, so maybe check one of the [previous
> versions](https://github.com/cztomsik/tokamak/tree/629dfd45bd95f310646d61f635604ec393253990)
> if you want to use it right now. The most up-to-date example is/might be in
> the [Ava PLS](https://github.com/cztomsik/ava) repository.

Server-side framework for Zig, relying heavily on dependency injection.

The code has been extracted from [Ava PLS](https://github.com/cztomsik/ava)
which has been using it for a few months already, and I'm using it in one other
project which is going to production soon, so it's not just a toy, it actually
works.

That said, it is **not designed to be used alone**, but with a reverse proxy in
front of it, like Nginx or Cloudfront, which will handle SSL, caching,
sanitization, etc.

## Getting started

Simple things should be easy to do.

```zig
const tk = @import("tokamak");

pub fn main() !void {
    var server = try tk.Server.start(allocator, hello, .{ .port = 8080 });
    server.wait();
}

fn hello() ![]const u8 {
    return "Hello";
}
```

## Dependency injection

The framework is built around the concept of dependency injection.
This means that your handler function can take any number of parameters, and the
framework will try to provide them for you.

Notable types you can inject are:

- `std.mem.Allocator` (request-scoped arena allocator)
- `*tk.Request` (current request, including headers, body reader, etc.)
- `*tk.Response` (current response, with methods to send data, set headers, etc.)
- `*tk.Injector` (the injector itself, see below)
- and everything you provide yourself

For example, you can you easily write a handler function which will create a
string on the fly and return it to the client without any tight coupling to the server or the request/response types.

```zig
fn hello(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Hello {}", .{std.time.timestamp()});
}
```

If you return any other type than `[]const u8`, the framework will try to
serialize it to JSON.

```zig
fn hello() !HelloRes {
    return .{ .message = "Hello" };
}
```

If you need a more fine-grained control over the response, you can inject a
`*tk.Response` and use its methods directly.

> But this will of course make your code tightly coupled to respective types
> and it should be avoided if possible.

```zig
fn hello(res: *tk.Response) !void {
    try res.sendJson(.{ .message = "Hello" });
}
```

## Custom dependencies

You can also provide your own (global) dependencies by passing your own
`tk.Injector` to the server.

```zig
pub fn main() !void {
    var db = try sqlite.open("my.db");

    var server = try tk.Server.start(allocator, hello, .{
        .injector = tk.Injector.from(.{ &db }),
        .port = 8080
    });

    server.wait();
}
```

## Middlewares

The framework supports special functions, called middlewares, which can alter
the flow of the request by either responding directly or calling the next
middleware.

For example, here's a simple logger middleware:

```zig
fn handleLogger(ctx: *Context) anyerror!void {
    log.debug("{s} {s}", .{ @tagName(ctx.req.method), ctx.req.url });

    return ctx.next();
}
```

As you can see, the middleware takes a `*Context` and returns `anyerror!void`.
It can do some pre-processing, logging, etc., and then call `ctx.next()` to
continue with the next middleware or the handler function.

There are few built-in middlewares, like `tk.chain()`, or `tk.send()`, and they
work similarly to Express.js except that we don't have closures in Zig, so some
things are a bit more verbose and/or need custom-scoping (see below).

```zig
var server = try tk.Server.start(gpa.allocator(), handler, .{ .port = 8080 });
server.wait();

const handler = tk.chain(.{
    // Log every request
    tk.logger(.{}),

    // Send "Hello" for GET requests to "/"
    tk.get("/", tk.send("Hello")),

    // Send 404 for anything else
    tk.send(error.NotFound),
});
```

## Custom-scoping

Zig doesn't have closures, so we can't just capture variables from the outer
scope. But what we can do is to use our dependency injection context to provide
some dependencies to any middleware or handler function further in the chain.

> Middlewares do not support the shorthand syntax for dependency injection,
> so you need to use `ctx.injector.get(T)` to get your dependencies manually.

```zig
fn auth(ctx: *Context) anyerror!void {
    const db = ctx.injector.get(*Db);
    const token = try jwt.parse(ctx.req.getHeader("Authorization"));
    const user = db.find(User, token.id) catch null;

    ctx.injector.push(&user);

    return ctx.next();
}
```

## Routing

There's a simple router built in, in the spirit of Express.js. It supports
up to 16 basic path params, and `*` wildcard.

```zig
const tk = @import("tokamak");

const api = struct {
    // Path params need to be in the order they appear in the path
    // Dependencies go always first
    pub fn @"GET /:name"(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Hello, {s}", .{name});
    }

    // In case of POST/PUT there's also a body
    // The body is deserialized from JSON
    pub fn @"POST /:id"(allocator: std.mem.Allocator, id: u32, data: struct {}) ![]const u8 {
        ...
    }

    ...
}

pub fn main() !void {
    var server = try tk.Server.start(allocator, api, .{ .port = 8080 });
    server.wait();
}
```

For the convenience, you can pass the api struct directly to the server, but
under the hood it's just another middleware, which you can compose to a
more complex hierarchy.

```zig
var server = try tk.Server.start(gpa.allocator(), handler, .{ .port = 8080 });
server.wait();

const handler = tk.chain(.{
    tk.logger(.{}),
    tk.get("/", tk.send("Hello")), // this is classic, express-style routing
    tk.group("/api", tk.router(api)), // and this is our shorthand
    tk.send(error.NotFound),
});

const api = struct {
    pub fn @"GET /"() []const u8 {
        return "Hello";
    }

    pub fn @"GET /:name"(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Hello {s}", .{name});
    }
};
```

## Error handling

If your handler returns an error, the framework will try to serialize it to
JSON and send it to the client.

```zig
fn hello() !void {
    // This will send 500 and {"error": "TODO"}
    return error.TODO;
}
```

## Static files

> This is outdated, you can use `tk.sendStatic()` middleware but it
> is likely not final solution either.

The response has a method to serve static files. It will call `root.embedFile()`
automatically in release builds, and `file.readToEndAlloc()` in debug builds.

We can't call `@embedFile()` directly, because it's module-scoped and it can't
read files from other modules. So there's this workaround:

```zig
pub fn embedFile(path: []const u8) []const u8 {
    return @embedFile(path);
}

fn hello(res: *tk.Response) !void {
    try res.sendResource("static/index.html");
}
```

## MIME types

The framework will try to guess the MIME type based on the file extension, but
you can also provide your own in the root module.

```zig
pub const mime_types = tk.mime_types ++ .{
    .{ ".foo", "text/foo" },
};
```

## Monitor

The `tk.monitor(procs)` allows you to execute multiple processes in parallel and
restart them automatically if they exit. It takes a tuple of `{ name, fn_ptr,
args_tuple }` triples as input. It will only work on systems with `fork()`.

What this means is that you can easily create a self-contained binary which will
stay up and running, even if something crashes unexpectedly.

> The function takes over the main thread, forks, and it might lead to
> unexpected behavior if you're not careful. Only use it if you know what you're
> doing.

```zig
monitor(.{
    .{ "server", &runServer, .{ 8080 } },
    .{ "worker", &runWorker, .{} },
    ...
});
```

## License

MIT
