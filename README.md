# Tokamak

📚 **[Documentation](https://tomsik.cz/tokamak)**

Tokamak is a server-side framework for Zig, built around
[http.zig](https://github.com/karlseguin/http.zig) and a simple dependency
injection container.

> **Note:** The main branch currently targets **Zig 0.15.2**.

Note that it is **not designed to be used alone**, but with a reverse proxy in
front of it, like Nginx or Cloudfront, which will handle SSL, caching,
sanitization, etc.

> ### Recent changes
> - renamed few `bundle.addXxx()` methods to `bundle.provide()`,
>   `bundle.override()`, ...
> - renamed `inj.call0(fun)` → `inj.call(fun)`, `inj.call(fun, ...args)` →
>   `inj.callArgs(fun, ...args)`
> - opt dependencies were removed, ie. you can no longer inject `?Cfg` - it was
>   undocumented, incomplete, subtly broken, and not worth the extra complexity
> - multi-mod API has changed
>   [considerably](https://github.com/cztomsik/tokamak/pull/25)
> - there's a new [cli module](https://github.com/cztomsik/tokamak/tree/master/src/cli.zig)
> - injecting `tk.Injector` is deprecated, use `*tk.Injector`
> - multi-module support (cross-module initializers, providers, overrides)
> - Switched to [http.zig](https://github.com/karlseguin/http.zig) for improved
>   performance over `std.http`.
> - Implemented hierarchical and introspectable routes.
> - Added basic Swagger support.
> - Added `tk.static.dir()` for serving entire directories.

## Installation

```bash
zig fetch --save "git+https://github.com/cztomsik/tokamak#main"
```

Then in your `build.zig`:

```zig
const tokamak = @import("tokamak");

pub fn build(b: *std.Build) void {
    ...
    const exe = b.addExecutable(.{ ... });
    ...

    // Add tokamak
    tokamak.setup(exe, .{});
}
```

## Getting Started

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
    
    var server = try tk.Server.init(allocator, routes, .{ .listen = .{ .port = 8080 } });
    try server.start();
}
```

## Dependency Injection

The framework is built around the concept of dependency injection.
This means that your handler function can take any number of parameters, and the
framework will try to provide them for you.

Notable types you can inject are:

- `std.mem.Allocator` (request-scoped arena allocator)
- `*tk.Request` (current request, including headers, body reader, etc.)
- `*tk.Response` (current response, with methods to send data, set headers, etc.)
- `*tk.Injector` (the injector itself, see below)
- and everything you provide yourself

For example, you can easily write a handler function which will create a
string on the fly and return it to the client without any tight coupling to the
server or the request/response types.

```zig
fn hello(arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "Hello {}", .{std.time.timestamp()});
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

## Custom Dependencies

You can also provide your own (global) dependencies by passing your own
`*tk.Injector` to the server.

```zig
pub fn main() !void {
    var db = try sqlite.open("my.db");
    var inj = tk.Injector.init(&.{ .ref(&db) }, null)

    var server = try tk.Server.init(allocator, routes, .{
        .injector = &inj,
        .port = 8080
    });

    try server.start();
}
```

> For advanced dependency injection features like multi-module support,
> intrusive interfaces, and lifecycle hooks, see the [Advanced Dependency
> Injection](#advanced-dependency-injection) section below.

## Middleware

While Tokamak doesn't have Express-style middleware, it achieves the same
functionality through nested routes. Since routes can be nested and the
`prefix`, `path`, and `method` fields are optional, you can create powerful
middleware patterns.

Here's how to create a simple logging middleware:

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

Middleware handlers receive a `*Context` and return `anyerror!void`. They can
perform pre-processing, logging, authentication, etc., and then call
`ctx.next()` to continue to the next handler in the chain.


## Request-Scoped Dependencies

Since Zig doesn't have closures, you can't capture variables from the outer
scope. Instead, Tokamak allows you to add request-scoped dependencies that will
be available to downstream handlers:

```zig
fn auth(ctx: *Context) anyerror!void {
    const db = ctx.injector.get(*Db);
    const token = try jwt.parse(ctx.req.getHeader("Authorization"));
    const user = db.find(User, token.id) catch null;

    return ctx.nextScoped(&.{ user });
}
```

> Note: Middleware handlers need to use `ctx.injector.get(T)` to access
> dependencies manually, as they don't support the automatic dependency
> injection syntax.

## Routing

Tokamak includes an Express-inspired router that supports path parameters and
wildcards. It can handle up to 16 path parameters and uses the `*` character for
wildcards.

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

For more organized routing, use the `Route.router(T)` method with a DSL-like
struct:

```zig
const routes: []const tk.Route = &.{
    tk.logger(.{}),
    .get("/", tk.send("Hello")),        // Classic Express-style routing
    .group("/api", &.{ .router(api) }), // Structured routing with a module
    .send(error.NotFound),
};

const api = struct {
    pub fn @"GET /"() []const u8 {
        return "Hello";
    }

    pub fn @"GET /:name"(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "Hello {s}", .{name});
    }
};
```

## Error Handling

Tokamak handles errors gracefully by automatically serializing them to JSON:

```zig
fn hello() !void {
    // This will send a 500 response with {"error": "TODO"}
    return error.TODO;
}
```

## Static Files

Serve static files easily with built-in helpers:

```zig
const routes: []const tk.Route = &.{
    .get("/", tk.static.file("public/index.html")),
};
```

Serve entire directories:

```zig
const routes: []const tk.Route = &.{
    tk.static.dir("public", .{}),
};
```

Use with wildcard routes for more flexibility:

```zig
const routes: []const tk.Route = &.{
    tk.get("/assets/*", tk.static.dir("assets", .{ .index = null })),
};
```

If you want to embed some files into the binary, you can specify such paths to
the `tokamak.setup()` call in your `build.zig` file.

```zig
const tokamak = @import("tokamak");

...

tokamak.setup(exe, .{
    .embed = &.{
        "public/index.html",
    },
});
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

## Configuration

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

## Process Monitoring

The `tk.monitor(procs)` function runs multiple processes in parallel and
automatically restarts them if they crash. This creates a self-healing
application that stays running even after unexpected failures.

```zig
monitor(.{
    .{ "server", &runServer, .{ 8080 } },
    .{ "worker", &runWorker, .{} },
    ...
});
```

It takes a tuple of `{ name, fn_ptr, args_tuple }` triples as input.

> **Note:** This feature requires a system with `fork()` support. It takes over
> the main thread and forks processes, which may lead to unexpected behavior if
> used incorrectly. Use with caution.

## Advanced Dependency Injection

### Multi-Module System

Tokamak supports a powerful multi-module system where dependencies are
automatically resolved across module boundaries. Modules are Zig structs where
fields become dependencies:

```zig
const SharedModule = struct {
    db_pool: DbPool,

    pub fn configure(bundle: *tk.Bundle) void {
        // Add more deps conditionally, override how they should be initialized, add hooks... (see below)
    }
};

const WebModule = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{ ... },
};

// Register modules when creating a Container
pub fn main() !void {
    try tk.app.run(Server.start, &.{
        SharedModule,
        WebModule,
    });
}
```

The Bundle API provides compile-time dependency configuration:

- `addModule(M)` - Add all fields of module M as dependencies
- `provide(T, how)` - Provide a single dependency with initialization strategy
- `override(T, how)` - Override dependency initialization (works across modules)
- `mock(T, how)` - Test-only override for mocking
- `expose(T, field)` - Expose a reference to a struct field as dependency
- `addInitHook(fn)` - Add runtime initialization callback
- `addDeinitHook(fn)` - Add runtime cleanup callback

Initialization strategies:
- `.auto` - Automatic initialization (uses `T.init()` if available, otherwise autowires struct fields)
- `.init` - Explicitly use `T.init()` method
- `.autowire` - Initialize struct by injecting all fields
- `.factory(fn)` - Use custom factory function
- `.initializer(fn)` - Use initializer function (receives pointer to initialize)
- `.value(v)` - Use provided comptime value directly

### Intrusive Interface Pattern

Tokamak supports an intrusive interface pattern for pluggable implementations.
Types with an `interface` field are automatically registered for dependency
injection, ie:

```
const AppModule = struct {
    http_client: StdClient,  // Define concrete implementation
};

// client will point to &StdClient.interface
fn handler(client: *HttpClient) !void {
    ...
}
```

### Testing

For testing, you can override dependencies:

```zig
const TestModule = struct {
    pub fn configure(bundle: *Bundle) void {
        bundle.mock(Database, .value(MockDatabase{}));
        bundle.mock(EmailService, .factory(createMockEmailService));
    }
};

// Run test with mocked dependencies
const ct = try Container.init(test_allocator, &.{AppModule, TestModule});
ct.injector.call(myTestFun)
```

## License

MIT
