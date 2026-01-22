# hello

The simplest example demonstrating a basic HTTP server with a single route.

## Source Code

**Path:** `examples/hello/`

```zig
@include examples/hello/src/main.zig
```

## The Handler

The handler function simply returns a string:

```zig
@include examples/hello/src/main.zig#L8-L10
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
