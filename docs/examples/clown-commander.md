# clown-commander

A terminal-based file manager inspired by Norton Commander and Midnight Commander.

## Source Code

**Path:** `examples/clown-commander/`

```zig
@include examples/clown-commander/src/main.zig
```

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
@include examples/clown-commander/src/main.zig#L8-L53
```

### Commander
Manages both panels:

```zig
@include examples/clown-commander/src/main.zig#L55-L88
```

## Main Loop

```zig
@include examples/clown-commander/src/main.zig#L240-L249
```

## TUI Context

The `tk.tui.Context` provides terminal control:

```zig
@include examples/clown-commander/src/main.zig#L237-L238
```

## File Operations

### Copy File
```zig
@include examples/clown-commander/src/main.zig#L185-L198
```

### Create Directory
```zig
@include examples/clown-commander/src/main.zig#L214-L222
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
