# tokamak

Server-side framework for Zig, relying heavily on dependency injection.

The code has been extracted from [Ava PLS](https://github.com/cztomsik/ava)
which has been using it for a few months already, and I'm using it in one other
project which is going to production soon, so it's not just a toy, it actually
works.

## Getting started

Simple things should be easy to do.

```zig
const tk = @import("tokamak");

pub fn main() !void {
    var server = tk.Server.start(allocator, hello, .{ .port = 8080 });
    try server.thread.join();
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
- `*tk.Responder` (wrapper around req + res, provides a few convenience methods)
- `*tk.Request` (current `std.http.Server.Request`)
- `*tk.Response` (current `std.http.Server.Response`)
- `tk.Injector` (the injector itself, see below)
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
`*tk.Responder` or even a `*tk.Response` and write to it directly.

But this will of course make your code tightly coupled to respective types.

```zig
fn hello(responder: *tk.Responder) !void {
    try responder.sendJson(.{ .message = "Hello" });
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
    var server = tk.Server.start(allocator, api, .{ .port = 8080 });
    try server.thread.join();
}
```

This works because the `Server.start()` function accepts `anytype`, so if it's
a function, it will use it as a handler for all requests and if it's a struct,
it will first call `tk.router()` on it to get a handler function, which is then
used.

You can call `tk.router()` yourself, if you want to do some pre-processing before
the router is called. For example, you can check for authentication, etc.

```zig
const tk = @import("tokamak");

const api = struct {
    pub fn @"GET /:name" ...

    ...
};

pub fn main() !void {
    var server = tk.Server.start(allocator, handleRequest, .{ .port = 8080 });
    try server.thread.join();
}

fn handleRequest(injector: tk.Injector, req: *tk.Request, responder: *tk.Responder) !void {
    // Check for authentication, etc.
    if (req.headers...) {
        ...
    }

    try responder.send(injector.call(tk.router(api), .{}));
}
```

## Middleware

There is no support for middleware yet, but you can usually get away with
the pattern above.

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

The responder has a method to serve static files. It will use `@embedFile`
automatically for release builds, and `file.readToEndAlloc()` for debug builds.

```zig
fn hello(responder: *tk.Responder) !void {
    try responder.sendResource("static/index.html");
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

## License

MIT
