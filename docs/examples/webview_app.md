# webview_app

A desktop application combining a web-based UI with native functionality.

## Source Code

**Path:** `examples/webview_app/`

## Features Demonstrated

- Webview integration for desktop apps
- Static file serving
- API endpoints for backend logic
- Server running in background thread
- C library integration (`@cImport`)
- Cross-platform desktop app development

## Prerequisites

This example requires the webview library to be installed on your system.

## Architecture

The application combines:
1. **Backend Server**: Runs in a separate thread, serves static files and API endpoints
2. **Webview Window**: Embeds a browser that loads the local server

```zig
const App = struct {
    server: tk.Server,
    server_opts: tk.ServerOptions = .{},
    routes: []const tk.Route = &.{
        .get("/*", tk.static.dir("public", .{})),
        .get("/api/hello", hello),
    },

    fn hello() ![]const u8 {
        return "Hello, world!";
    }
};
```

## How It Works

### 1. Create DI Container
```zig
const ct = try tk.Container.init(gpa.allocator(), &.{App});
defer ct.deinit();
```

### 2. Start Server in Background
```zig
const server = try ct.injector.get(*tk.Server);
const port = server.http.config.port.?;

const thread = try server.http.listenInNewThread();
defer thread.join();
```

### 3. Create and Show Webview
```zig
const w = c.webview_create(if (builtin.mode == .Debug) 1 else 0, null);
defer _ = c.webview_destroy(w);

_ = c.webview_set_title(w, "Example");
_ = c.webview_set_size(w, 800, 500, c.WEBVIEW_HINT_NONE);

const url = try std.fmt.allocPrintSentinel(
    gpa.allocator(),
    "http://127.0.0.1:{}",
    .{port},
    0
);
defer gpa.allocator().free(url);

_ = c.webview_navigate(w, url);
_ = c.webview_run(w);  // Blocks until window is closed
server.stop();
```

## Routes

### Static Files
```zig
.get("/*", tk.static.dir("public", .{}))
```
Serves all files from the `public/` directory. The frontend HTML/JS/CSS goes here.

### API Endpoint
```zig
.get("/api/hello", hello)
```
Backend API that the frontend can call.

## Frontend Integration

Your frontend JavaScript can call the backend API:

```javascript
fetch('/api/hello')
  .then(response => response.text())
  .then(data => console.log(data));
```

## Development vs Production

The webview can show dev tools in debug mode:

```zig
const w = c.webview_create(
    if (builtin.mode == .Debug) 1 else 0,  // 1 = show dev tools
    null
);
```

## Running

```sh
cd examples/webview_app
zig build run
```

A desktop window will open showing your web UI.

## Use Cases

This pattern is great for:
- Desktop applications with web UI
- Tools that need native OS integration
- Applications requiring file system access
- Cross-platform GUI apps without heavy frameworks

## Architecture Benefits

- **Familiar Technologies**: Build UI with HTML/CSS/JavaScript
- **Backend Power**: Full Zig capabilities for system operations
- **Small Binary**: No Electron overhead
- **Native Performance**: Direct system access from Zig backend

## Next Steps

- Add more API endpoints for your application logic
- Implement file system operations in the backend
- Use WebSockets for real-time communication
- Explore the webview library for more platform-specific features
