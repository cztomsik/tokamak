# tokamak

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
    server.thread.join();
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
`*tk.Response` and use its methods directly.

````zig

But this will of course make your code tightly coupled to respective types.

```zig
fn hello(res: *tk.Response) !void {
    try res.sendJson(.{ .message = "Hello" });
}
````

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
    server.thread.join();
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
    var server = try tk.Server.start(allocator, handleRequest, .{ .port = 8080 });
    server.thread.join();
}

fn handleRequest(injector: tk.Injector, req: *tk.Request, res: *tk.Response) !void {
    // Check for authentication, etc.
    if (req.headers...) {
        ...
    }

    try res.send(injector.call(tk.router(api), .{}));
}
```

## Custom dependencies

You can also provide your own dependencies:

```zig
pub fn main() !void {
    var globals = .{
        .db = try sqlite.open("db.sqlite3"),
    };

    var server = try tk.Server.start(allocator, hello, .{
        .injector = tk.Injector.from(&globals),
        .port = 8080
    });

    server.thread.join();
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

## License

MIT
