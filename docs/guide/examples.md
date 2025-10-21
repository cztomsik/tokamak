# Examples

Tokamak comes with several examples that demonstrate different features and use cases. All examples can be found in the `examples/` directory.

## hello

**Path:** `examples/hello/`

The simplest example demonstrating a basic HTTP server with a single route.

```zig
const std = @import("std");
const tk = @import("tokamak");

const routes: []const tk.Route = &.{
    .get("/", hello),
};

fn hello() ![]const u8 {
    return "Hello, world!";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try tk.Server.init(gpa.allocator(), routes, .{});
    defer server.deinit();

    try server.start();
}
```

**Features demonstrated:**
- Basic server setup
- Simple routing
- Handler functions

**Run:** `cd examples/hello && zig build run`

## hello_app

**Path:** `examples/hello_app/`

A more streamlined version of the hello example using the app framework with dependency injection.

```zig
const std = @import("std");
const tk = @import("tokamak");

const App = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{
        .get("/", hello),
    },

    fn hello() ![]const u8 {
        return "Hello, world!";
    }
};

pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{App});
}
```

**Features demonstrated:**
- Application framework (`tk.app`)
- Dependency injection container
- Declarative server configuration

**Run:** `cd examples/hello_app && zig build run`

## hello_cli

**Path:** `examples/hello_cli/`

A comprehensive CLI application demonstrating various commands and integrations.

**Features demonstrated:**
- CLI command framework (`tk.cli`)
- HTTP client integration
- HTML to Markdown conversion
- DOM parsing and querying
- PDF generation
- Regular expressions and grep functionality
- GitHub API integration
- Hacker News API integration

**Available commands:**
- `hello` - Print a greeting message
- `hn <limit>` - Show top Hacker News stories
- `gh <owner>` - List GitHub repos for a user
- `scrape <url> [selector]` - Scrape a URL with optional CSS selector
- `grep <file> <pattern>` - Search for pattern in file
- `substr <str> [start] [end]` - Get substring with bounds checking
- `pdf <filename> <title>` - Generate a sample PDF

**Run:** `cd examples/hello_cli && zig build run -- hello`

## hello_ai

**Path:** `examples/hello_ai/`

Demonstrates AI agent integration with function calling capabilities.

**Features demonstrated:**
- AI client configuration
- Agent runtime and toolbox
- Function/tool registration
- Multi-step agent workflows
- Service dependencies and state management

**Services:**
- `MathService` - Basic arithmetic operations (add, multiply)
- `MailService` - Email message listing

**Example tasks:**
- Math calculations using multiple tool calls
- Email analysis and formatting
- Sending emails via sendmail integration

**Run:** `cd examples/hello_ai && zig build run`

**Note:** Requires a local LLM server (see comments in source for llama-server examples).

## blog

**Path:** `examples/blog/`

A REST API example with Swagger UI documentation and static file serving.

**Features demonstrated:**
- REST API with CRUD operations
- Service layer architecture (`BlogService`)
- OpenAPI/Swagger integration
- Static file serving
- Route grouping and middleware
- Logger middleware

**Endpoints:**
- `GET /api/posts` - List all posts
- `POST /api/posts` - Create a new post
- `GET /api/posts/:id` - Get a single post
- `PUT /api/posts/:id` - Update a post
- `DELETE /api/posts/:id` - Delete a post
- `GET /swagger-ui` - Interactive API documentation
- `GET /openapi.json` - OpenAPI specification

**Run:** `cd examples/blog && zig build run`

**Visit:** http://localhost:8080/swagger-ui

## todos_orm_sqlite

**Path:** `examples/todos_orm_sqlite/`

A complete REST API using SQLite database with ORM integration.

**Features demonstrated:**
- Database integration with [fridge ORM](https://github.com/cztomsik/fridge)
- Connection pooling
- Database migrations
- CRUD operations with SQL
- PATCH endpoint with partial updates
- Lifecycle hooks (`configure`, `initDb`)
- Custom middleware composition

**Endpoints:**
- `GET /todo` - List all todos
- `GET /todo/:id` - Get a single todo
- `POST /todo` - Create a new todo
- `PUT /todo/:id` - Update a todo (full replacement)
- `PATCH /todo/:id` - Partially update a todo
- `DELETE /todo/:id` - Delete a todo

**Configuration:**
- By default uses in-memory SQLite (`:memory:`)
- Change `db_opts.filename` to persist to disk

**Run:** `cd examples/todos_orm_sqlite && zig build run`

**Example:**
```sh
# Create a todo
curl -X POST -H "content-type: application/json" \
  -d '{ "title": "my todo" }' \
  http://localhost:8080/todo

# List all todos
curl http://localhost:8080/todo

# Patch a todo
curl -X PATCH -H "content-type: application/json" \
  -d '{ "is_done": true }' \
  http://localhost:8080/todo/1
```

## webview_app

**Path:** `examples/webview_app/`

A desktop application combining a web-based UI with native functionality.

**Features demonstrated:**
- Webview integration for desktop apps
- Static file serving
- API endpoints for backend logic
- Server running in background thread
- C library integration (@cImport)
- Cross-platform desktop app development

**Architecture:**
- Backend server runs in a separate thread
- Webview loads the local server URL
- Frontend can communicate with backend via HTTP API

**Run:** `cd examples/webview_app && zig build run`

**Note:** Requires webview library to be installed on your system.

## clown-commander

**Path:** `examples/clown-commander/`

A terminal-based file manager inspired by Norton Commander / Midnight Commander.

**Features demonstrated:**
- TUI (Terminal User Interface) framework
- Dual-panel file navigation
- Keyboard event handling
- File system operations (copy, delete, mkdir)
- Interactive user input
- ANSI escape codes and terminal control

**Controls:**
- Arrow keys (↑↓←→) - Navigate and switch panels
- Tab - Switch between panels
- Enter - Enter directory
- F5 or 'c' - Copy file
- F7 or 'm' - Create directory
- F8 or 'd' - Delete file/directory
- 'q' or Ctrl-C - Quit

**Run:** `cd examples/clown-commander && zig build run`

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

## Common Patterns

### Application Framework

Most examples use the `tk.app.run()` function which:
- Sets up the dependency injection container
- Initializes all services and dependencies
- Calls any registered init hooks
- Runs the specified entry function
- Handles cleanup on shutdown

### Dependency Injection

Services are defined as struct fields in the `App` struct and are automatically:
- Instantiated by the DI container
- Injected into handlers and other services
- Cleaned up on shutdown

### Route Handlers

Handlers can inject dependencies as parameters:
- `allocator: std.mem.Allocator` - Arena allocator per request
- `res: *tk.Response` - Response object
- `req: *tk.Request` - Request object
- Custom services (e.g., `*BlogService`, `*fr.Session`)
- Path parameters by name
- Request body via type parameter

See the [Routing Guide](/guide/routing) and [Dependency Injection Guide](/guide/dependency-injection) for more details.
