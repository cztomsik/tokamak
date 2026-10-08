# hello_app

A more streamlined version of the hello example using the application framework with dependency injection. Its build selects the httpz HTTP backend; the app framework works with either backend.

## Source Code

**Path:** `examples/hello_app/`

```zig
@include examples/hello_app/src/main.zig
```

## Features Demonstrated

- Application framework (`tk.app`)
- Dependency injection container
- Declarative server configuration
- Automatic memory management
- Clean, minimal boilerplate
- Build-time HTTP backend selection via `tokamak.setup(exe, .{ .backend = .httpz })`

## How It Works

The `tk.app.run()` function:
1. Creates a dependency injection container
2. Initializes all services defined in `App`
3. Calls the entry function (`tk.Server.start`)
4. Handles cleanup on shutdown

## Running

```sh
cd examples/hello_app
zig build run
```

Visit http://localhost:8080/ to see the greeting.

## Comparison with `hello`

Both examples serve the same greeting using the shared routing and handler
API. Their build files select different HTTP backends; either backend works
with either application style. Compared with manual server setup, the app
framework:
- Eliminates manual allocator setup
- Automatically manages the server lifecycle
- Provides a cleaner, more declarative API
- Is the recommended approach for Tokamak applications

## Next Steps

- See [blog](./blog.md) for a full application with services and middleware
- Check out [todos_orm_sqlite](./todos_orm_sqlite.md) for database integration
