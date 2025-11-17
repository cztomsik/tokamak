# Dependency Injection

Tokamak is built around dependency injection, allowing handlers to declare their dependencies as function parameters.

## Basic Injection

Handlers can request dependencies simply by adding parameters:

```zig
fn hello(arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "Hello {}", .{std.time.timestamp()});
}
```

## Built-in Dependencies

These types can be injected into any handler:

- `std.mem.Allocator` - Request-scoped arena allocator
- `*tk.Request` - Current HTTP request
- `*tk.Response` - Current HTTP response
- `*tk.Injector` - The DI container itself

## Response Types

Handlers have flexible return types:

### Return String

```zig
fn hello() ![]const u8 {
    return "Hello";
}
```

### Return JSON

Any type other than `[]const u8` is automatically serialized to JSON:

```zig
const HelloRes = struct { message: []const u8 };

fn hello() !HelloRes {
    return .{ .message = "Hello" };
}
```

### Manual Response Control

For fine-grained control, inject `*tk.Response`:

```zig
fn hello(res: *tk.Response) !void {
    try res.json(.{ .message = "Hello" }, .{});
}
```

::: tip
Avoid tight coupling to `*tk.Response` when possible. Prefer returning values directly.
:::

## Custom Dependencies

Provide your own global dependencies via a custom injector:

```zig
pub fn main() !void {
    var db = try sqlite.open("my.db");
    var cache = try Cache.init();

    var inj = tk.Injector.init(&.{
        .ref(&db),
        .ref(&cache),
    }, null);

    var server = try tk.Server.init(allocator, routes, .{
        .injector = &inj,
    });

    try server.start();
}
```

Now handlers can inject these dependencies:

```zig
fn getUser(db: *sqlite.Database, cache: *Cache, id: []const u8) !User {
    if (cache.get(id)) |user| return user;
    const user = try db.find(User, id);
    try cache.set(id, user);
    return user;
}
```

## Multi-Module System

For larger applications, organize dependencies into modules:

```zig
const SharedModule = struct {
    db_pool: DbPool,
    cache: Cache,
};

const WebModule = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{ /* ... */ },
};

pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{
        SharedModule,
        WebModule,
    });
}
```

### Bundle API

Configure module dependencies with the Bundle API:

```zig
const AppModule = struct {
    db: Database,

    pub fn configure(bundle: *tk.Bundle) void {
        // Provide dependencies
        bundle.provide(Logger, .factory(createLogger));

        // Override existing dependencies
        bundle.override(Cache, .factory(createRedisCache));

        // Add lifecycle hooks
        bundle.addInitHook(onInit);
        bundle.addDeinitHook(onDeinit);
    }
};
```

Initialization strategies:

- `.auto` - Automatic initialization
- `.init` - Use `T.init()` method
- `.autowire` - Inject all struct fields
- `.factory(fn)` - Custom factory function
- `.value(v)` - Compile-time value

## Testing with Mocks

Override dependencies for testing:

```zig
const TestModule = struct {
    pub fn configure(bundle: *tk.Bundle) void {
        bundle.mock(Database, .value(MockDatabase{}));
        bundle.mock(EmailService, .factory(createMockEmail));
    }
};

test "user registration" {
    const ct = try tk.Container.init(
        test_allocator,
        &.{ AppModule, TestModule }
    );
    defer ct.deinit();

    try ct.injector.call(testUserRegistration);
}
```

## Intrusive Interfaces

Types with an `interface` field are automatically registered:

```zig
const HttpClient = struct {
    get: *const fn(*HttpClient, []const u8) anyerror![]const u8,
};

const StdClient = struct {
    interface: HttpClient,
    // ... implementation
};

const AppModule = struct {
    http_client: StdClient,
};

// Handlers receive the interface pointer
fn fetchData(client: *HttpClient, url: []const u8) ![]const u8 {
    return client.get(client, url);
}
```
