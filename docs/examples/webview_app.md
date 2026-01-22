# webview_app

A desktop application combining a web-based UI with native functionality.

## Source Code

**Path:** `examples/webview_app/`

```zig
@include examples/webview_app/src/main.zig
```

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
@include examples/webview_app/src/main.zig#L5-L16
```

## How It Works

The main function shows the complete flow:

```zig
@include examples/webview_app/src/main.zig#L18-L48
```

## Routes

Routes are defined in the App struct:

```zig
@include examples/webview_app/src/main.zig#L8-L11
```

- `.get("/*", tk.static.dir("public", .{}))` serves all files from the `public/` directory
- `.get("/api/hello", hello)` is a backend API that the frontend can call

## Frontend Integration

Your frontend JavaScript can call the backend API:

```javascript
fetch('/api/hello')
  .then(response => response.text())
  .then(data => console.log(data));
```

## Development vs Production

The webview can show dev tools in debug mode (see line 36 in the source):

```zig
@include examples/webview_app/src/main.zig#L36-L37
```

The first argument to `webview_create` is `1` for dev tools enabled, `0` for disabled.

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
