# Process Monitoring

The `tk.monitor()` function provides a robust process monitoring system that runs multiple processes in parallel with automatic restart on crashes, creating a self-healing application.

## Basic Usage

```zig
const std = @import("std");
const tk = @import("tokamak");

pub fn main() !void {
    // Do initial setup checks if needed

    return tk.monitor(.{
        .{ "server", &runServer, .{ 8080 } },
        .{ "worker 1", &runWorker, .{ 1 } },
        .{ "worker 2", &runWorker, .{ 2 } },
    });
}

fn runServer(port: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try tk.Server.init(gpa.allocator(), routes, .{
        .listen = .{ .port = port }
    });
    try server.start();
}

fn runWorker(id: u32) !void {
    while (true) {
        // Process background jobs
        std.time.sleep(std.time.ns_per_s);
    }
}
```

## How It Works

The monitor function:

1. Takes a tuple of process definitions: `.{ "name", &fn_ptr, .{ ...args } }`
2. Forks each process on startup
3. Monitors all child processes continuously
4. Automatically restarts any process that exits
5. Logs process lifecycle events (start, exit)

## Process Structure

Each process definition is a tuple with three elements:

- **Name** (`[]const u8`): A descriptive name for the process (shown in logs)
- **Function** (`*const fn`): Pointer to the function to run
- **Arguments** (tuple): Arguments to pass to the function

```zig
.{ "worker", &processJobs, .{ db, queue_name } }
```

## Process Title

The monitor automatically sets the process title to help with identification in process lists (`ps`, `top`, etc.):

```bash
$ ps aux | grep myapp
user  1234  myapp: server
user  1235  myapp: worker 1
user  1236  myapp: worker 2
```

## Logging

The monitor uses scoped logging. Enable debug logs to see process lifecycle events:

```zig
pub const std_options = struct {
    pub const log_level = .debug;
};
```

Output:
```
debug: start: #0 server pid: 1234
debug: start: #1 worker 1 pid: 1235
debug: exit: #1 worker 1 pid: 1235
debug: start: #1 worker 1 pid: 1236
```

## Error Handling

If a process function returns an error:

1. The error name is logged
2. Stack trace is dumped if available
3. Process exits with code 1
4. Monitor automatically restarts the process

```zig
fn riskyWorker() !void {
    return error.DatabaseConnectionFailed;  // Will be logged and restarted
}
```

## Use Cases

### Multi-Server Setup

Run multiple servers on different ports:

```zig
tk.monitor(.{
    .{ "http", &runHTTP, .{ 8080 } },
    .{ "https", &runHTTPS, .{ 8443 } },
    .{ "admin", &runAdmin, .{ 9000 } },
});
```

### Server + Background Workers

Combine HTTP server with background job processors:

```zig
tk.monitor(.{
    .{ "api", &runServer, .{} },
    .{ "email-worker", &processEmailQueue, .{} },
    .{ "image-worker", &processImageQueue, .{} },
    .{ "cleanup-worker", &cleanupOldFiles, .{} },
});
```

### Development vs Production

```zig
pub fn main() !void {
    if (is_production) {
        return tk.monitor(.{
            .{ "server", &runServer, .{} },
        });
    } else {
        try runServer();
    }
}
```

## Important Notes

::: warning System Requirements
- Requires POSIX-compliant system with `fork()` support
- Not available on Windows
- Linux and macOS are supported
:::

::: danger Takes Over Main Thread
The monitor function takes over the main thread and never returns (it's marked as `noreturn`). Perform all initialization before calling `tk.monitor()`.
:::

::: tip Resource Management
Each forked process gets its own memory space. Initialize resources (allocators, database connections, etc.) within each process function, not before the monitor call.
:::

## Best Practices

### Initialize Per-Process Resources

```zig
fn runServer(port: u16) !void {
    // Create allocator INSIDE the process function
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try tk.Server.init(gpa.allocator(), routes, .{
        .listen = .{ .port = port }
    });
    try server.start();
}
```

### Graceful Shutdown

```zig
fn runWorker() !void {
    while (true) {
        processJobs() catch |err| {
            std.log.err("Job processing failed: {}", .{err});
            // Continue running, don't exit
        };
    }
}
```

### Shared Configuration

```zig
pub fn main() !void {
    // Load config once, before forking
    const config = try loadConfig();

    return tk.monitor(.{
        .{ "server", &runServer, .{ config.port } },
        .{ "worker", &runWorker, .{ config.queue } },
    });
}
```
