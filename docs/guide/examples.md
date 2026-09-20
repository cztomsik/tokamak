# Examples

Tokamak comes with several examples that demonstrate different features and use cases. All examples can be found in the `examples/` directory.

## Server Examples

### [hello](../examples/hello.md)
The simplest example demonstrating a basic HTTP server with a single route.

### [hello_app](../examples/hello_app.md)
A more streamlined version using the app framework with dependency injection.

### [blog](../examples/blog.md)
A REST API example with Swagger UI documentation and static file serving.

### [todos_orm_sqlite](../examples/todos_orm_sqlite.md)
A complete REST API using SQLite database with ORM integration.

### [webview_app](../examples/webview_app.md)
A desktop application combining a web-based UI with native functionality.

## CLI Examples

### [hello_cli](../examples/hello_cli.md)
A comprehensive CLI application demonstrating various commands and integrations.

## Building Examples

All examples use Zig's build system. To build and run any example:

```sh
cd examples/<example-name>
zig build run
```

To just build without running:

```sh
zig build
```

The built binary will be in `zig-out/bin/`.
