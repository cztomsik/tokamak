# clown-commander

A terminal-based file manager inspired by Norton Commander and Midnight Commander.

## Source Code

**Path:** `examples/clown-commander/`

## Features Demonstrated

- TUI (Terminal User Interface) framework
- Dual-panel file navigation
- Keyboard event handling
- File system operations (copy, delete, mkdir)
- Interactive user input
- ANSI escape codes and terminal control

## Controls

| Key | Action |
|-----|--------|
| ↑ ↓ | Navigate up/down in current panel |
| ← → | Switch to left/right panel |
| Tab | Toggle between panels |
| Enter | Enter directory (or parent if on `..`) |
| F5 or 'c' | Copy selected file to other panel |
| F7 or 'm' | Create new directory |
| F8 or 'd' | Delete selected file/directory |
| 'q' or Ctrl-C | Quit application |

## Architecture

### Panel
Each panel manages its own state:

```zig
const Panel = struct {
    path: []u8,
    files: std.ArrayList(FileInfo),
    selected: usize,

    fn init(allocator: std.mem.Allocator, path: []const u8) !Panel
    fn refresh(self: *Panel, allocator: std.mem.Allocator) !void
    fn navigateUp(self: *Panel) void
    fn navigateDown(self: *Panel) void
    fn getCurrentFile(self: *Panel) ?FileInfo
};
```

### Commander
Manages both panels:

```zig
const Commander = struct {
    allocator: std.mem.Allocator,
    left: Panel,
    right: Panel,
    active: enum { left, right },

    fn getActivePanel(self: *Commander) *Panel
    fn getInactivePanel(self: *Commander) *Panel
};
```

## Main Loop

```zig
while (true) {
    try displayPanels(&commander, ctx);
    try ctx.flush();

    const key = try ctx.readKey();

    switch (key) {
        .char => |c| switch (c) {
            'q' => break,
            'c' => try copyFile(&commander),
            'd' => try deleteFile(&commander),
            'm' => try createDirectory(&commander, ctx),
            else => {},
        },
        .ctrl_c => break,
        .tab => commander.active = if (commander.active == .left) .right else .left,
        .up => commander.getActivePanel().navigateUp(),
        .down => commander.getActivePanel().navigateDown(),
        .enter => try enterDirectory(&commander),
        // ...
    }
}
```

## TUI Context

The `tk.tui.Context` provides terminal control:

```zig
const ctx = try tk.tui.Context.init(allocator);
defer ctx.deinit();

// Clear screen
try ctx.clear();

// Print formatted text
try ctx.println("│{s:<38}│{s:<38}│", .{ left_text, right_text });

// Read keyboard input
const key = try ctx.readKey();

// Read line of text
const input = try ctx.readLine(&buffer);

// Flush output
try ctx.flush();
```

## File Operations

### Copy File
```zig
fn copyFile(commander: *Commander) !void {
    const src_panel = commander.getActivePanel();
    const dst_panel = commander.getInactivePanel();
    const file = src_panel.getCurrentFile() orelse return;

    // Build source and destination paths
    const src_path = try std.fs.path.join(commander.allocator,
        &.{ src_panel.path, file.name });
    const dst_path = try std.fs.path.join(commander.allocator,
        &.{ dst_panel.path, file.name });

    // Copy and refresh
    try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{});
    try dst_panel.refresh(commander.allocator);
}
```

### Create Directory
```zig
fn createDirectory(commander: *Commander, ctx: *tk.tui.Context) !void {
    try ctx.print("Enter directory name: ", .{});
    try ctx.flush();

    var name_buf: [256]u8 = undefined;
    const dir_name = try ctx.readLine(&name_buf) orelse return;

    const dir_path = try std.fs.path.join(commander.allocator,
        &.{ panel.path, dir_name });

    try std.fs.cwd().makeDir(dir_path);
    try panel.refresh(commander.allocator);
}
```

## Display Layout

The interface uses box-drawing characters for a clean TUI:

```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│/home/user/project                    │/home/user/downloads                  │
├──────────────────────────────────────┼──────────────────────────────────────┤
│>[..]                                 │ [..]                                 │
│ [src]                                │ [documents]                          │
│ [test]                               │>[music]                              │
│ main.zig                             │ file.txt                             │
│ README.md                            │ image.png                            │
└──────────────────────────────────────┴──────────────────────────────────────┘
↑↓: navigate  Tab/←→: switch panels  Enter: enter dir  F5/c: copy  q: quit
```

## Running

```sh
cd examples/clown-commander
zig build run
```

The application will launch in your terminal with a dual-panel file browser.

## Tips

- Directories are shown with `[brackets]`
- The active panel's selected item is marked with `>`
- Use `..` to navigate to parent directory
- The app starts in your current working directory

## Next Steps

- See [hello_cli](./hello_cli.md) for CLI command patterns
- Check out the [TUI reference](/tui) for more TUI capabilities
- Explore keyboard event handling for custom controls
