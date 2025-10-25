# TUI

Terminal user interface module with raw mode and keyboard input support.

**Requirements:** TTY (does not work with piped/redirected I/O)

## Context

```zig
tk.tui.Context.init(allocator: std.mem.Allocator) !*Context
```

Creates TUI context, switches terminal to raw mode, and sets up buffered I/O.

Returns `error.NotATty` if stdin is not a terminal.

```zig
var ctx = try tk.tui.Context.init(allocator);
defer ctx.deinit();
```

**Side effects:**
- Saves original terminal settings
- Switches to raw mode (no line buffering, no echo)
- Disables canonical mode and special character processing
- Sets up 4KB output buffer, 1KB input buffer

### deinit()

```zig
ctx.deinit() void
```

Restores original terminal settings and frees resources.

Always call via `defer`.

## Input

### readKey()

```zig
ctx.readKey() !Key
```

Reads single keypress from input. Blocks until key is available.

Returns parsed key event (see Key union).

### readLine()

```zig
ctx.readLine(buf: []u8) !?[]const u8
```

Reads line of input with basic editing support.

**Features:**
- Backspace editing
- Visual echo of characters
- Buffer overflow protection

**Returns:**
- Slice of `buf` containing input (excluding newline)
- `null` if cancelled (Escape, Ctrl+C, Ctrl+D)

## Output

### print()

```zig
ctx.print(comptime fmt: []const u8, args: anytype) !void
```

Formatted output to buffered stdout.

Use `\r\n` for line breaks in raw mode.

### println()

```zig
ctx.println(comptime fmt: []const u8, args: anytype) !void
```

Same as `print()` but appends `\r\n`.

### clear()

```zig
ctx.clear() !void
```

Clears screen using ANSI escape sequence.

### flush()

```zig
ctx.flush() !void
```

Flushes output buffer to terminal.

**Required** after any output operation for immediate display.

## Key Union

```zig
tk.tui.Key = union(enum) {
    char: u8,
    up, down, left, right,
    home, end,
    page_up, page_down,
    tab, enter, backspace, delete, escape,
    ctrl_c, ctrl_d,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
}
```

Represents parsed keyboard input.

**Usage:**

```zig
const key = try ctx.readKey();
switch (key) {
    .char => |c| handleChar(c),
    .enter => handleEnter(),
    .ctrl_c => break,
    else => {},
}
```

## ANSI Support

Access ANSI codes via `tk.ansi`:

```zig
const ansi = @import("tokamak").ansi;

try ctx.print("{s}Error{s}\r\n", .{ ansi.red, ansi.reset });
```

Available codes:
- `clear` - Clear screen
- `red`, `green`, `blue`, etc. - Color codes
- `reset` - Reset formatting

## Platform Support

**Supported:**
- Linux (POSIX terminals)
- macOS (POSIX terminals)
- Windows (with Windows Terminal or compatible emulator)

**Not supported:**
- Piped input/output
- Non-TTY environments

## Error Handling

```zig
error.NotATty
```

Returned when stdin is not a terminal. Handle gracefully:

```zig
const ctx = tk.tui.Context.init(allocator) catch |err| {
    if (err == error.NotATty) return runBatchMode();
    return err;
};
```

## Raw Mode Details

Context initialization configures terminal with:
- `lflag = {}` - No canonical mode, no echo, no signals
- `iflag = {}` - No input processing
- `oflag.OPOST = false` - No output processing
- `VMIN = 1` - Read returns after 1 character
- `VTIME = 0` - No timeout

Terminal is restored to original state on `deinit()`.
