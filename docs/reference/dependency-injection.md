# Dependency Injection

Compile-time dependency injection container with automatic resolution.

## Injector

```zig
tk.Injector.init(providers: []const Provider, parent: ?*Injector) Injector
```

Creates an injector with the given providers.

```zig
var injector = tk.Injector.init(&.{
    .ref(&db),
    .ref(&cache),
}, null);
```

### Provider Types

```zig
.ref(ptr)              // Reference to existing value
.value(val)            // Compile-time value
.factory(fn)           // Factory function
.init                  // Call T.init()
.autowire              // Inject all struct fields
```

### get()

```zig
injector.get(T: type) !T
```

Retrieves a dependency of type `T`.

```zig
const db = try injector.get(*Database);
```

## Handler Injection

Handlers automatically receive dependencies as parameters:

```zig
fn handler(db: *Database, cache: *Cache, id: []const u8) !User {
    // Dependencies injected automatically
}
```

### Built-in Types

Always available for injection:

- `std.mem.Allocator` - Request-scoped arena allocator
- `*tk.Request` - HTTP request
- `*tk.Response` - HTTP response
- `*tk.Injector` - Injector instance
- `*tk.Context` - Request context (middleware only)

### Return Types

**String**: Sent as-is with `text/plain`
```zig
fn handler() []const u8 { return "Hello"; }
```

**Struct/Other**: Serialized to JSON
```zig
fn handler() User { return user; }
```

**void**: No response body
```zig
fn handler(res: *tk.Response) !void {
    try res.json(.{ .status = "ok" }, .{});
}
```

## Multi-Module System

```zig
tk.app.run(fn, modules: []const type) !void
```

Initializes a container from multiple modules and runs the provided function.

```zig
const App = struct {
    db: Database,
    server: tk.Server,
};

pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{App});
}
```

### Module Definition

Module fields become dependencies:

```zig
const DbModule = struct {
    db: Database,
    pool: ConnectionPool,
};

const WebModule = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{ /* ... */ },
};
```

## Container API

```zig
tk.Container.init(allocator: std.mem.Allocator, modules: []const type) !Container
```

Creates a container from modules without running.

```zig
const ct = try tk.Container.init(allocator, &.{App});
defer ct.deinit();

// Access the injector
const db = try ct.injector.get(*Database);
```

## Bundle Configuration

Modules can implement `configure()` to customize initialization:

```zig
const AppModule = struct {
    db: Database,

    pub fn configure(bundle: *tk.Bundle) void {
        bundle.provide(Logger, .factory(createLogger));
        bundle.override(Cache, .factory(createRedisCache));
        bundle.addInitHook(onInit);
        bundle.addDeinitHook(onDeinit);
    }
};
```

### Bundle Methods

**provide(T, how)**
Provide a dependency with initialization strategy.

**addModule(M)**
Add all fields of module M as dependencies.

**override(T, how)**
Override existing dependency initialization.

**mock(T, how)**
Test-only override for mocking.

**expose(T, field)**
Expose a reference to a struct field as dependency.

**addInitHook(fn)**
Add runtime initialization callback.

**addDeinitHook(fn)**
Add runtime cleanup callback.

### Initialization Strategies

- `.auto` - Automatic (uses `T.init()` if available, otherwise autowires)
- `.init` - Call `T.init()` method
- `.autowire` - Initialize struct by injecting all fields
- `.factory(fn)` - Use custom factory function
- `.initializer(fn)` - Use initializer function (receives pointer)
- `.value(v)` - Use provided compile-time value

## Intrusive Interfaces

Types with an `interface` field are automatically registered for injection:

```zig
const HttpClient = struct {
    get: *const fn(*HttpClient, []const u8) anyerror![]const u8,
};

const StdClient = struct {
    interface: HttpClient,
    // implementation
};

const AppModule = struct {
    http_client: StdClient,  // Registers StdClient
};

// Handlers receive the interface pointer
fn handler(client: *HttpClient) ![]const u8 {
    return client.get(client, "https://example.com");
}
```

## Testing

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

## Request-Scoped Dependencies

Middleware can add request-scoped dependencies:

```zig
fn auth(ctx: *tk.Context) !void {
    const db = ctx.injector.get(*Database);
    const user = try authenticateUser(db, ctx.req);

    // Add user to request scope
    return ctx.nextScoped(&.{ user });
}

// Downstream handlers can inject User
fn getProfile(user: User) !Profile {
    return Profile{ .id = user.id, .name = user.name };
}
```
