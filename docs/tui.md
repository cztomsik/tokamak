# TUI (Terminal User Interface)

Terminal user interface module for interactive terminal applications.

## Overview

Features:

- Raw terminal mode (character-by-character input)
- Keyboard input parsing (arrows, function keys, control keys)
- Line editing with backspace
- Buffered I/O
- Terminal state management

::: warning TTY Required
Requires a TTY. Does not work with piped or redirected I/O.
:::

## Setup

```zig
const std = @import("std");
const tk = @import("tokamak");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ctx = try tk.tui.Context.init(gpa.allocator());
    defer ctx.deinit();

    try ctx.clear();
    try ctx.println("Welcome to my TUI app!", .{});
    try ctx.flush();

    while (true) {
        const key = try ctx.readKey();

        switch (key) {
            .ctrl_c, .ctrl_d, .escape => break,
            .char => |c| {
                try ctx.print("You pressed: {c}\r\n", .{c});
                try ctx.flush();
            },
            else => {},
        }
    }
}
```

## Context Initialization

Context manages terminal state and I/O:

```zig
var ctx = try tk.tui.Context.init(allocator);
defer ctx.deinit();
```

Initialization:
- Verifies stdin is a TTY
- Saves original terminal settings
- Switches to raw mode
- Sets up buffered I/O
- Restores terminal on deinit

## Keyboard Input

### Reading Keys

```zig
const key = try ctx.readKey();

switch (key) {
    .char => |c| std.debug.print("Character: {c}\n", .{c}),
    .enter => std.debug.print("Enter pressed\n", .{}),
    .escape => std.debug.print("Escape pressed\n", .{}),
    .up => std.debug.print("Up arrow\n", .{}),
    .ctrl_c => break,
    else => {},
}
```

### Available Keys

The `tk.tui.Key` union supports:

**Regular Keys:**
- `.char` - Any printable character
- `.enter` - Enter/Return key
- `.tab` - Tab key
- `.backspace` - Backspace
- `.delete` - Delete key
- `.escape` - Escape key

**Arrow Keys:**
- `.up`, `.down`, `.left`, `.right`

**Navigation:**
- `.home`, `.end`
- `.page_up`, `.page_down`

**Control Keys:**
- `.ctrl_c` - Ctrl+C
- `.ctrl_d` - Ctrl+D

**Function Keys:**
- `.f1` through `.f12`

## Line Reading

Read a line of input with basic editing:

```zig
var buf: [256]u8 = undefined;

try ctx.print("Enter your name: ", .{});
try ctx.flush();

if (try ctx.readLine(&buf)) |line| {
    try ctx.println("Hello, {s}!", .{line});
} else {
    try ctx.println("Cancelled", .{});
}
try ctx.flush();
```

Features:
- Backspace support for editing
- Visual feedback (echoes characters)
- Returns `null` on Escape/Ctrl+C/Ctrl+D
- Handles buffer limits safely

## Output Functions

### Print

```zig
try ctx.print("Score: {d}\r\n", .{score});
try ctx.flush();
```

::: tip Line Endings
Use `\r\n` instead of just `\n` in raw mode for proper line breaks.
:::

### Println

Convenience function that adds `\r\n`:

```zig
try ctx.println("Hello, {s}!", .{name});
try ctx.flush();
```

### Clear Screen

```zig
try ctx.clear();
try ctx.flush();
```

### Flush Buffer

Always flush after output to see changes:

```zig
try ctx.print("Loading", .{});
try ctx.flush();
```

## Interactive Menu Example

```zig
const std = @import("std");
const tk = @import("tokamak");

const MenuItem = struct {
    name: []const u8,
    key: u8,
};

const menu = [_]MenuItem{
    .{ .name = "New Game", .key = 'n' },
    .{ .name = "Load Game", .key = 'l' },
    .{ .name = "Settings", .key = 's' },
    .{ .name = "Quit", .key = 'q' },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ctx = try tk.tui.Context.init(gpa.allocator());
    defer ctx.deinit();

    try ctx.clear();
    try ctx.println("=== Main Menu ===", .{});
    try ctx.println("", .{});

    for (menu) |item| {
        try ctx.println("  [{c}] {s}", .{ item.key, item.name });
    }

    try ctx.println("", .{});
    try ctx.print("Select: ", .{});
    try ctx.flush();

    while (true) {
        const key = try ctx.readKey();

        switch (key) {
            .char => |c| {
                for (menu) |item| {
                    if (c == item.key) {
                        try ctx.println("{c}", .{c});
                        try ctx.println("Selected: {s}", .{item.name});
                        try ctx.flush();

                        if (c == 'q') return;

                        std.time.sleep(std.time.ns_per_s);
                        return main();
                    }
                }
            },
            .ctrl_c, .escape => return,
            else => {},
        }
    }
}
```

## Form Input Example

```zig
const UserInput = struct {
    name: []const u8,
    email: []const u8,
    age: u32,
};

pub fn getUserInput(ctx: *tk.tui.Context, allocator: std.mem.Allocator) !UserInput {
    var name_buf: [100]u8 = undefined;
    var email_buf: [100]u8 = undefined;
    var age_buf: [10]u8 = undefined;

    try ctx.println("=== User Registration ===", .{});
    try ctx.println("", .{});

    try ctx.print("Name: ", .{});
    try ctx.flush();
    const name_line = try ctx.readLine(&name_buf) orelse return error.Cancelled;
    const name = try allocator.dupe(u8, name_line);

    try ctx.print("Email: ", .{});
    try ctx.flush();
    const email_line = try ctx.readLine(&email_buf) orelse return error.Cancelled;
    const email = try allocator.dupe(u8, email_line);

    try ctx.print("Age: ", .{});
    try ctx.flush();
    const age_line = try ctx.readLine(&age_buf) orelse return error.Cancelled;
    const age = try std.fmt.parseInt(u32, age_line, 10);

    return UserInput{
        .name = name,
        .email = email,
        .age = age,
    };
}
```

## ANSI Escape Codes

The TUI module uses ANSI escape sequences. You can use the `ansi` module for colors and formatting:

```zig
const ansi = @import("tokamak").ansi;

try ctx.print("{s}Error:{s} Invalid input\r\n", .{ ansi.red, ansi.reset });
try ctx.print("{s}Success!{s}\r\n", .{ ansi.green, ansi.reset });
try ctx.flush();
```

## Progress Indicator Example

```zig
pub fn showProgress(ctx: *tk.tui.Context, total: usize) !void {
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const percent = (i * 100) / total;

        try ctx.print("\rProgress: {d}% ", .{percent});
        try ctx.flush();

        std.time.sleep(100 * std.time.ns_per_ms);
    }

    try ctx.println("\rProgress: 100% - Complete!", .{});
    try ctx.flush();
}
```

## Best Practices

### Always Flush

Output is buffered for performance. Remember to flush:

```zig
try ctx.print("Message", .{});
try ctx.flush();  // Don't forget this!
```

### Handle Cleanup

Always use `defer` to ensure terminal is restored:

```zig
var ctx = try tk.tui.Context.init(allocator);
defer ctx.deinit();  // Essential!
```

### Use Line Endings

In raw mode, use `\r\n` for line breaks:

```zig
// Wrong
try ctx.print("Hello\n", .{});

// Right
try ctx.print("Hello\r\n", .{});

// Or use println
try ctx.println("Hello", .{});
```

### Check for TTY

Provide fallback for non-TTY environments:

```zig
const ctx = tk.tui.Context.init(allocator) catch |err| {
    if (err == error.NotATty) {
        // Fall back to regular I/O
        return runNonInteractive();
    }
    return err;
};
defer ctx.deinit();
```

## Limitations

::: warning Platform Support
- Requires POSIX-compliant terminal
- Linux and macOS are supported
- Windows support requires Windows Terminal or compatible emulator
:::

::: warning Feature Scope
This is a minimal TUI library. For advanced features like:
- Complex layouts
- Windows/panels
- Mouse support
- Colors (beyond basic ANSI)

Consider using a dedicated TUI library.
:::

## Use Cases

The TUI module is perfect for:

- Interactive CLI tools
- Setup wizards
- Configuration prompts
- Simple text-based games
- Admin consoles
- Development tools

Not recommended for:
- Complex dashboard applications
- Applications requiring sophisticated layouts
- Production-critical user interfaces
