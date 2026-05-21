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

fn hello(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "Hello, {s}!", .{name});
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

## Building Interactive Terminal Apps (TUI)

The TUI module provides a **double-buffered, immediate-mode** rendering system for building rich terminal user interfaces. Unlike traditional TUI libraries that manage widgets as persistent objects, Tokamak's approach re-renders the entire UI each frame.

### Core Concepts

- **Event Loop**: Call `ctx.tick()` in a loop. It returns `.render`, `.key`, or `.idle` events.
- **Builder**: On `.render` events, you receive a `Builder` object to compose your UI.
- **Layout**: Use `push()`, `stack()`, `row()`, `grid()`, and `pushEq()` to create nested layout scopes.
- **Widgets**: Call widget functions on the Builder (`ui.button()`, `ui.text()`, etc.) to render into the current layout cell.
- **Controls**: Use `ui.control(&value)` to register interactive elements. Tab/Shift+Tab cycles focus.
- **State**: Use `ui.state(T, default)` for per-widget persistent state across frames (similar to React hooks).
- **Themes**: Built-in themes: `.nord`, `.dracula`, `.ayu_mirage`, `.catppuccin_mocha`, `.catppuccin_latte`.

### Your First TUI App

```zig
const std = @import("std");
const tk = @import("tokamak");

var counter: i32 = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var cx = try tk.tui.Context.init(gpa.allocator());
    defer cx.deinit();

    while (true) {
        switch (try cx.tick()) {
            .render => |ui| {
                if (ui.stack(-1)) |s| {
                    s.label("Counter: " ++ cx.fmt("{d}", .{counter}));
                    if (s.button("Increment")) counter += 1;
                    if (s.button("Decrement")) counter -= 1;
                    if (s.button("Quit")) break;
                }
            },
            .key => |k| {
                if (k == .ctrl_c or k == .escape) break;
                cx.pending_key = k;
            },
            else => {},
        }
    }
}
```

The `tick()` method drives the render loop:
1. **`.render`** — Your UI function receives a `Builder` to describe the frame.
2. **`.key`** — A keypress was received. Assign it to `cx.pending_key` to make it available to widgets on the next render, or handle it directly for global shortcuts.
3. **`.idle`** — No input, nothing to do.

### Layout System

The layout system is a row-wrapping grid. You define column widths and a height, then claim cells by calling widgets or `ui.next()`.

#### Basic Containers

```zig
// A single-column stack that fills remaining height
if (ui.stack(-1)) |s| {
    s.label("Line 1");
    s.label("Line 2");
}

// A row with two equal columns
if (ui.pushEq(2, 3)) |r| {
    // Each cell gets 50% of the width, 3 rows tall
}

// A grid with explicit column widths
if (ui.grid(&.{ 30, -1 }, -1)) |g| {
    // First column is 30 chars wide, second fills the rest
    // Height fills remaining space
}
```

#### Sizing

Widths and heights can be specified in several ways:

- **Positive number** — Absolute size in cells (e.g., `10` = 10 columns)
- **`-1`** — Fill all remaining space
- **Negative N** — N cells from the right/bottom edge (e.g., `-10` = everything except the last 10)
- **`tk.tui.perc(f32)`** — Percentage (e.g., `tk.tui.perc(33.3)` for ~1/3)

```zig
// Three equal columns
if (ui.pushEq(3, -1)) |g| { /* ... */ }

// Same thing with explicit percentages
if (ui.grid(&.{ tk.tui.perc(33.3), tk.tui.perc(33.3), tk.tui.perc(33.4) }, -1)) |g| {
    // ...
}

// Sidebar + main content
if (ui.grid(&.{ 25, -1 }, -1)) |g| {
    // 25-char sidebar, rest is main
}
```

### Widgets

All widgets are called on a `Builder` and render into the next available layout cell.

#### Text Widgets

```zig
ui.label("Hello, world!");
ui.text("Plain text");
ui.num(42);                    // Renders any numeric value
ui.paragraph("Long text that wraps " ++ "across multiple lines", -1); // -1 = auto-height
ui.kvRow("Name: ", "Tokamak"); // Key-value row with dimmed label
ui.header("Section Title");    // Dashed separator with centered title
ui.separator();                // Horizontal line
ui.spacer(2);                  // Empty vertical space
```

#### Interactive Controls

```zig
// Button — returns true when pressed (Enter/Space)
if (ui.button("Click me")) {
    // ...
}

// Checkbox — toggles on Enter/Space
ui.checkbox("Enable feature", &enabled);

// Text input — single-line with cursor editing
var buf: [128]u8 = undefined;
var len: usize = 0;
ui.textInput(&buf, &len);

// Text area — multi-line with wrapping
var area_buf: [512]u8 = undefined;
var area_len: usize = 0;
ui.textArea(&area_buf, &area_len, 6); // 6 rows tall

// Number input — type digits or use arrows
ui.numberInput(&count, 1); // step = 1

// Slider — left/right arrows or mouse wheel
ui.slider(&volume, 0.05); // value in 0.0..1.0, step = 0.05

// Select — up/down to navigate, Enter to confirm
if (ui.select(3, &selected_index)) |sel| {
    sel.item("Option A");
    sel.item("Option B");
    sel.item("Option C");
}
```

#### Container Widgets

Container widgets return an optional `Builder` for nested content:

```zig
// Panel — bordered box
if (ui.panel(-1)) |p| {
    p.label("Inside a panel");
}

// Collapsible section — toggles on Enter/Space
var open: bool = true;
if (ui.collapsible("Details", &open)) {
    ui.label("Hidden content");
}

// Tabs — left/right to switch
if (ui.tabs(3, &tab_index)) |t| {
    t.item("Overview");
    t.item("Settings");
    t.item("Data");
}

// Menu bar — pinned to bottom, F1-F10 keys
if (ui.menu(4)) |m| {
    if (m.item(.f1, "Help")) { /* ... */ }
    if (m.item(.f5, "Reset")) { /* ... */ }
    if (m.item(.f9, "Theme")) { /* ... */ }
    if (m.item(.f10, "Quit")) { /* ... */ }
}
```

#### Overlays

```zig
// Status bar — pinned to bottom row
ui.statusBar("Ready  (F10: Quit)");

// Flash message — centered overlay
ui.flash("Operation completed!");

// Modal dialog — centered overlay with border and shadow
var show_modal: bool = true;
if (ui.modal(&show_modal, "Confirm", 40, 6)) |m| {
    m.label("Are you sure?");
    if (m.row(&.{ 10, 10 })) |r| {
        if (r.button("Yes")) { /* ... */ }
        if (r.button("No")) show_modal = false;
    }
}

// Generic overlay — full control over positioning
if (ui.overlay(50, 10)) |o| {
    o.frame.fill(ui.ctx.theme.base3);
    o.frame.border(.all);
    o.label("Custom overlay");
}
```

#### Feedback Widgets

```zig
ui.spinner();          // Animated spinner: | / - \
ui.progress(0.75);     // Progress bar (0.0..1.0)
ui.alert("Error!", .red); // Alert message
```

#### Tree View

```zig
const items = &[_][]const u8{ "Root", "Child A", "Leaf 1", "Leaf 2", "Child B", "Leaf 3" };
const depths = &[_]u8{ 0, 1, 2, 2, 1, 2 };
ui.tree(items, depths, &selected);
```

### Focus and Controls

Interactive widgets need to be registered as controls to receive keyboard input. Most widgets do this automatically. Use `ui.control(&value)` to create a control manually:

```zig
const ctrl = ui.control(&my_value);

if (ctrl.focused) {
    // This widget has keyboard focus
}

if (ctrl.pressed()) {
    // Enter or Space was pressed while focused
}

// Navigate with up/down keys among N items
ctrl.navigate(.{ .up, .down }, items.len);

// Toggle a boolean
ctrl.toggle();
```

Tab and Shift+Tab cycle focus through all registered controls.

### Persistent State

Use `ui.state(T, default)` to store state that persists across frames. The state is keyed by the widget's return address, similar to React hooks:

```zig
fn myWidget(ui: Builder) void {
    const count = ui.state(usize, 0);
    ui.label(ui.ctx.fmt("Clicked {d} times", .{count.*}));
    if (ui.button("Click")) count.* += 1;
}
```

### Themes

Set the theme on the context before rendering:

```zig
cx.theme = .nord;              // Default — cool blue tones
cx.theme = .dracula;           // Purple/pink dark theme
cx.theme = .ayu_mirage;        // Blue/green dark theme
cx.theme = .catppuccin_mocha;  // Purple dark theme
cx.theme = .catppuccin_latte;  // Purple light theme
```

You can also define a custom theme:

```zig
cx.theme = .{
    .text = .white,
    .base1 = .black,
    .base2 = tk.tui.Color.rgb(0x33, 0x33, 0x33),
    .base3 = tk.tui.Color.rgb(0x22, 0x22, 0x22),
    .primary = tk.tui.Color.rgb(0x88, 0xCC, 0xFF),
    .secondary = tk.tui.Color.rgb(0x88, 0x88, 0xAA),
    .accent = tk.tui.Color.rgb(0x66, 0x66, 0x66),
};
```

### Frame Primitives

For low-level drawing, use the `Frame` object. Frames represent a rectangular region and support chaining:

```zig
const f = ui.next(-1, 1) orelse return;

f.text("Hello");           // Draw text at origin
f.fill(.blue);             // Fill background
f.splat("─");              // Repeat a character across the frame
f.draw(5, 0, "►");         // Draw at specific position
f.border(.all);            // Draw box border
f.shadow();                // Add drop shadow
f.hline(0, 0, 20);         // Horizontal line
f.vline(10, 0, 10);        // Vertical line

// Frame transformations
const inner = f.pad(.{ 1, 1, 1, 1 });   // Shrink by 1 on each side
const left = f.left(10);                // Left 10 columns
const right = f.right(10);              // Right 10 columns
const top = f.top(2);                   // Top 2 rows
const bottom = f.bottom(1);             // Bottom row
const center = f.center(20, 5);         // Centered 20x5
const sub = f.sub(2, 1, 10, 3);         // Sub-frame at (2,1) size 10x3

// Change foreground color for a sub-region
f.with("fg", .red).text("Error!");
```

### Complete Example

Here's a more complete app showing the patterns together:

```zig
const std = @import("std");
const tk = @import("tokamak");
const Builder = tk.tui.Builder;

const State = struct {
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    dark_mode: bool = true,
    quit: bool = false,
};

var state: State = .{};

pub fn main() !void {
    var cx = try tk.tui.Context.init(std.heap.c_allocator);
    defer cx.deinit();

    while (!state.quit) {
        cx.theme = if (state.dark_mode) .nord else .catppuccin_latte;

        switch (try cx.tick()) {
            .render => |ui| render(ui),
            .key => |k| switch (k) {
                .ctrl_c, .escape => state.quit = true,
                .scroll_up => {}, // custom handling
                .scroll_down => {},
                else => cx.pending_key = k,
            },
            else => {},
        }
    }
}

fn render(ui: Builder) void {
    // Header panel
    if (ui.panel(2)) |p| {
        p.label("My App");
    }

    // Main content area
    if (ui.stack(-1)) |s| {
        s.kvRow("Name: ", if (state.name_len > 0) state.name_buf[0..state.name_len] else "(empty)");
        s.checkbox("Dark mode", &state.dark_mode);
        s.textInput(&state.name_buf, &state.name_len);
        s.spacer(1);
        if (s.button("Save")) {
            // ...
        }
        if (s.button("Quit")) state.quit = true;
    }

    // Bottom menu
    if (ui.menu(2)) |m| {
        _ = m.item(.f9, "Theme");
        _ = m.item(.f10, "Quit");
    }
}
```

### Important Notes

> **TTY Required**: TUI features only work when running in a real terminal. They won't work with piped input/output or when running as a background process.

> **Arena Allocator**: The context uses an internal arena allocator that resets each frame. Strings created with `ctx.fmt()` are only valid for the current frame.

> **Focus Management**: Interactive widgets auto-register as controls. Use Tab/Shift+Tab to cycle focus. Modal dialogs automatically shift focus into their content.

> **Event Flow**: `tick()` follows the cycle: clear → render → flush → poll → idle → poll → ... When you want to force a re-render (e.g., for animations), set `cx.next_tick = .render`.
