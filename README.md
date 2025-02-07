# tokamak

Tokamak is a server-side framework for Zig, built around
[http.zig](https://github.com/karlseguin/http.zig) and a simple dependency
injection container.

Note, that it is **not designed to be used alone**, but with a reverse proxy in
front of it, like Nginx or Cloudfront, which will handle SSL, caching,
sanitization, etc.

> ### Recent changes
> - Switched to [http.zig](https://github.com/karlseguin/http.zig) for improved
>   performance over `std.http`.
> - Implemented hierarchical and introspectable routes.
> - Added basic Swagger support.
> - Added `tk.static.dir()` for serving entire directories.

## Getting started

Simple things should be easy to do.

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
    
    const server = try tk.Server.init(allocator, routes, .{ .listen = .{ .port = 8080 } });
    try server.start();
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
- `tk.Injector` (the injector itself, see below)
- and everything you provide yourself

For example, you can easily write a handler function which will create a
string on the fly and return it to the client without any tight coupling to the
server or the request/response types.

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
    try res.json(.{ .message = "Hello" }, .{});
}
```

## Custom dependencies

You can also provide your own (global) dependencies by passing your own
`tk.Injector` to the server.

```zig
pub fn main() !void {
    var db = try sqlite.open("my.db");
    var cx = .{ &db };

    const server = try tk.Server.init(allocator, routes, .{
        .injector = tk.Injector.init(&cx, null),
        .port = 8080
    });

    try server.start();
}
```

## Middlewares

We don't have 1:1 middleware support like in Express.js, but given that our
routes can be nested and that the `prefix`, `path` and `method` fields are
optional, you can easily achieve the same effect.

For example, here's a simple function which will return a logger route:

```zig
fn logger(children: []const Route) tk.Route {
    const H = struct {
        fn handleLogger(ctx: *Context) anyerror!void {
            log.debug("{s} {s}", .{ @tagName(ctx.req.method), ctx.req.url });

            return ctx.next();
        }

    };
    return .{ .handler = &H.handleLogger, .children = children };
}

const routes = []const tk.Route = &.{
    logger(&.{
        .get("/", hello),
    }),
};
```

As you can see, the handler takes a `*Context` and returns `anyerror!void`.
It can do some pre-processing, logging, etc., and then call `ctx.next()` to
continue with the next handler in the chain.


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

    return ctx.nextScoped(&.{ user });
}
```

## Routing

There's a simple router built in, in the spirit of Express.js. It supports
up to 16 basic path params, and `*` wildcard. The example below shows how deps
and params will be passed to the handler function.

```zig
const tk = @import("tokamak");

const routes: []const tk.Route = &.{
    .get("/", hello),                        // fn(...deps)
    .get("/hello/:name", helloName),         // fn(...deps, name)
    .get("/hello/:name/:age", helloNameAge), // fn(...deps, name, age)
    .get("/hello/*", helloWildcard),         // fn(...deps)
    .post("/hello", helloPost),              // fn(...deps, body)
    .post0("/hello", helloPost0),            // fn(...deps)
    ...
};
```

There's also `Route.router(T)` method, which accepts special DSL-like struct,
which allows you to define routes together with the fns in a single place.

```zig
const routes: []const tk.Route = &.{
    tk.logger(.{}),
    .get("/", tk.send("Hello")),        // this is the classic, express-style routing
    .group("/api", &.{ .router(api) }), // and this is our shorthand
    .send(error.NotFound),
};

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

To send a static file, you can use the `tk.static.file(path)` middleware.

```zig
const routes: []const tk.Route = &.{
    .get("/", tk.static.file("static/index.html")),
};
```

You can also serve entire directories with `tk.static.dir(path)`.

```zig
const routes: []const tk.Route = &.{
    tk.static.dir("public", .{}),
};
```

And of course, the `tk.static.dir()` also works with wildcard routes.

```zig
const routes: []const tk.Route = &.{
    tk.get("/assets/*", tk.static.dir("assets", .{ .index = null })),
};
```

If you want to embed some files into the binary, you can specify such paths to
the `tokamak` module in your `build.zig` file.

```zig
const embed: []const []const u8 = &.{
    "static/index.html",
};

const tokamak = b.dependency("tokamak", .{ .embed = embed });
exe.root_module.addImport("tokamak", tokamak.module("tokamak"));
```

In this case, only the files listed in the `embed` array will be embedded into
the binary and any other files will be served from the filesystem.

## MIME types

The framework will try to guess the MIME type based on the file extension, but
you can also provide your own in the root module.

```zig
pub const mime_types = tk.mime_types ++ .{
    .{ ".foo", "text/foo" },
};
```

## Config

For a simple configuration, you can use the `tk.config.read(T, opts)` function,
which will read the configuration from a JSON file. The `opts` parameter is
optional and can be used to specify the path to the config file and parsing
options.

```zig
const Cfg = struct {
    foo: u32,
    bar: []const u8,
};

const cfg = try tk.config.read(Cfg, .{ .path = "config.json" });
```

There's also experimental `tk.config.write(T, opts)` function, which will write
the configuration back to the file.

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
