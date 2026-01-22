# hello_app

A more streamlined version of the hello example using the application framework with dependency injection.

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

This example is functionally identical to `hello` but uses the app framework, which:
- Eliminates manual allocator setup
- Automatically manages the server lifecycle
- Provides a cleaner, more declarative API
- Is the recommended approach for Tokamak applications

## Next Steps

- See [blog](./blog.md) for a full application with services and middleware
- Check out [todos_orm_sqlite](./todos_orm_sqlite.md) for database integration
