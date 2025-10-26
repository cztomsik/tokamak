# Terminal

Beyond web applications, Tokamak includes tools for building command-line interfaces and interactive terminal applications. These tools let you reuse your application's dependencies and services in CLI tools and TUI apps.

## Building CLI Tools

The CLI module helps you create command-line tools that can share your server application's configuration and dependencies. This is perfect for administrative tasks like database migrations, data imports, or maintenance scripts.

### Your First Command

Let's create a simple CLI tool with a couple of commands:

```zig
const std = @import("std");
const tk = @import("tokamak");

const commands = &[_]tk.cli.Command{
    .cmd0("version", "Show version", version),
    .cmd1("hello", "Greet someone", hello),
};

fn version() []const u8 {
    return "1.0.0";
}

fn hello(name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var injector = tk.Injector.init(&.{}, null);
    try tk.cli.run(&injector, gpa.allocator(), commands);
}
```

Now you can run:

```bash
$ myapp version
1.0.0

$ myapp hello World
Hello, World!
```

### Sharing Dependencies with Your Server

The real power comes from reusing your application's services and database connections:

```zig
// Your server application's module
const AppModule = struct {
    db: Database,
    config: Config,
};

// CLI commands that use the same dependencies
const commands = &[_]tk.cli.Command{
    .cmd0("migrate", "Run database migrations", migrate),
    .cmd1("find-user", "Find user by email", findUser),
};

fn migrate(db: *Database) !void {
    try db.runMigrations();
}

fn findUser(db: *Database, email: []const u8) !User {
    return db.findByEmail(email);
}

pub fn main() !void {
    const ct = try tk.Container.init(allocator, &.{AppModule});
    defer ct.deinit();

    try tk.cli.run(&ct.injector, allocator, commands);
}
```

Now your CLI tool has access to the same database connection, configuration, and services as your server!

### Output Formats

CLI commands support multiple output formats. By default, strings are printed as-is and structs are formatted as YAML:

```bash
$ myapp find-user john@example.com
id: 123
name: John Doe
email: john@example.com
```

Need JSON instead? Just add the `--json` flag:

```bash
$ myapp --json find-user john@example.com
{
  "id": 123,
  "name": "John Doe",
  "email": "john@example.com"
}
```

This makes it easy to pipe output to other tools or save to files.

## Building Interactive Terminal Apps

The TUI module lets you build interactive terminal applications with keyboard input and raw mode control. Perfect for wizards, menus, or any interactive tool.

### Getting Started with TUI

Here's a simple interactive program:

```zig
const std = @import("std");
const tk = @import("tokamak");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ctx = try tk.tui.Context.init(gpa.allocator());
    defer ctx.deinit();

    try ctx.clear();
    try ctx.println("Welcome! Press any key (ESC to quit)...", .{});
    try ctx.flush();

    while (true) {
        const key = try ctx.readKey();

        switch (key) {
            .escape, .ctrl_c => break,
            .char => |c| {
                try ctx.println("You pressed: {c}", .{c});
                try ctx.flush();
            },
            .enter => {
                try ctx.println("Enter pressed!", .{});
                try ctx.flush();
            },
            else => {},
        }
    }

    try ctx.println("Goodbye!", .{});
    try ctx.flush();
}
```

The TUI context handles all the terminal setup for you - switching to raw mode, capturing input, and restoring everything when you're done.

### Reading User Input

You can easily read line input with built-in editing support:

```zig
var name_buf: [100]u8 = undefined;

try ctx.print("What's your name? ", .{});
try ctx.flush();

if (try ctx.readLine(&name_buf)) |name| {
    try ctx.println("Hello, {s}!", .{name});
} else {
    try ctx.println("Cancelled", .{});
}
try ctx.flush();
```

The `readLine` function gives users backspace editing and returns `null` if they press Escape or Ctrl+C.

### Building Menus

Here's a simple menu system:

```zig
try ctx.clear();
try ctx.println("=== Main Menu ===", .{});
try ctx.println("", .{});
try ctx.println("  [n] New Game", .{});
try ctx.println("  [l] Load Game", .{});
try ctx.println("  [q] Quit", .{});
try ctx.println("", .{});
try ctx.print("Select: ", .{});
try ctx.flush();

while (true) {
    const key = try ctx.readKey();

    switch (key) {
        .char => |c| {
            switch (c) {
                'n' => {
                    try ctx.println("n", .{});
                    try ctx.println("Starting new game...", .{});
                    try ctx.flush();
                    // Start new game
                    break;
                },
                'l' => {
                    try ctx.println("l", .{});
                    try ctx.println("Loading game...", .{});
                    try ctx.flush();
                    // Load game
                    break;
                },
                'q' => return,
                else => {},
            }
        },
        .escape, .ctrl_c => return,
        else => {},
    }
}
```

### Important Notes

::: tip Always Flush
The TUI context uses buffered output for performance. Always call `ctx.flush()` after output operations to see your changes immediately.
:::

::: tip Line Endings in Raw Mode
In raw mode, use `\r\n` for line breaks instead of just `\n`. Or use `ctx.println()` which handles this for you.
:::

::: warning TTY Required
TUI features only work when running in a real terminal. They won't work with piped input/output or when running as a background process.
:::

### Adding Color

You can use ANSI escape codes for colors and formatting:

```zig
const ansi = @import("tokamak").ansi;

try ctx.print("{s}Error:{s} Something went wrong\r\n", .{
    ansi.red,
    ansi.reset,
});
try ctx.print("{s}Success!{s}\r\n", .{
    ansi.green,
    ansi.reset,
});
try ctx.flush();
```

## Common Patterns

### Configuration Wizard

Combine TUI input with your application configuration:

```zig
pub fn runConfigWizard(ctx: *tk.tui.Context, allocator: std.mem.Allocator) !Config {
    var port_buf: [10]u8 = undefined;
    var name_buf: [100]u8 = undefined;

    try ctx.println("=== Application Setup ===", .{});
    try ctx.println("", .{});

    try ctx.print("Server port [8080]: ", .{});
    try ctx.flush();
    const port_str = try ctx.readLine(&port_buf) orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    try ctx.print("Application name: ", .{});
    try ctx.flush();
    const name_line = try ctx.readLine(&name_buf) orelse return error.Cancelled;

    return Config{
        .port = port,
        .name = try allocator.dupe(u8, name_line),
    };
}
```

### Admin CLI with Database

Build admin tools that use your production database:

```zig
const commands = &[_]tk.cli.Command{
    .cmd1("ban-user", "Ban user by email", banUser),
    .cmd1("stats", "Show user statistics", showStats),
};

fn banUser(db: *Database, email: []const u8) !void {
    const user = try db.findByEmail(email);
    try db.banUser(user.id);
}

fn showStats(db: *Database, metric: []const u8) !Stats {
    return db.getStats(metric);
}
```

### Interactive Setup Script

Combine both for a complete setup experience:

```zig
pub fn main() !void {
    // Use TUI for interactive setup
    var ctx = try tk.tui.Context.init(allocator);
    defer ctx.deinit();

    const config = try runConfigWizard(&ctx, allocator);

    // Save config and show CLI commands for next steps
    try config.save("config.json");

    try ctx.println("", .{});
    try ctx.println("Setup complete! You can now run:", .{});
    try ctx.println("  myapp migrate    # Run database migrations", .{});
    try ctx.println("  myapp serve      # Start the server", .{});
    try ctx.flush();
}
```

## What's Next?

For detailed API reference and advanced features:

- **[CLI Reference](/reference/cli)** - Command definitions, context API, output formats
- **[TUI Reference](/reference/tui)** - Keyboard input, terminal control, raw mode details
