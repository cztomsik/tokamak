# CLI

Command-line interface module for building CLI tools with dependency injection support.

## run()

```zig
tk.cli.run(injector: *Injector, allocator: std.mem.Allocator, commands: []const Command) !void
```

Executes CLI command parsing and routing. Blocks until command completes.

```zig
var injector = tk.Injector.init(&.{ .ref(&db) }, null);
try tk.cli.run(&injector, allocator, commands);
```

**Output flags:**
- `--json` - JSON output format
- `--yaml` - YAML output format
- Default: Auto (strings as-is, structs as YAML)

## Command

```zig
tk.cli.Command.cmd0(name: []const u8, description: []const u8, handler: fn) Command
tk.cli.Command.cmd1(name: []const u8, description: []const u8, handler: fn) Command
tk.cli.Command.cmd2(name: []const u8, description: []const u8, handler: fn) Command
tk.cli.Command.cmd3(name: []const u8, description: []const u8, handler: fn) Command
tk.cli.Command.cmd(name: []const u8, description: []const u8, handler: fn, n_args: usize) Command
```

Creates command definitions for different argument counts.

```zig
const commands = &[_]tk.cli.Command{
    .cmd0("version", "Show version", getVersion),
    .cmd1("hello", "Greet user", hello),
    .cmd2("add-user", "Create user", addUser),
};
```

### Built-in Command

```zig
tk.cli.Command.usage
```

Displays help information. Automatically included.

## Handler Functions

Handlers can inject dependencies and accept command arguments:

```zig
// No dependencies, no arguments
fn version() []const u8

// With dependencies, no arguments
fn migrate(db: *Database) !void

// With dependencies and arguments
fn findUser(db: *Database, id: []const u8) !User

// With allocator
fn hello(arena: std.mem.Allocator, name: []const u8) ![]const u8
```

**Argument order:**
1. Injected dependencies (from DI container)
2. Command arguments (from CLI args)

**Optional arguments:**

```zig
fn greet(name: []const u8, title: ?[]const u8) ![]const u8
```

## Context

```zig
tk.cli.Context
```

Available as injectable dependency for advanced control.

**Fields:**
- `arena: std.mem.Allocator` - Request-scoped allocator
- `bin: []const u8` - Binary name
- `command: *const Command` - Current command
- `args: []const []const u8` - Remaining arguments
- `in: *std.io.Reader` - stdin
- `out: *std.io.Writer` - stdout
- `err: *std.io.Writer` - stderr
- `injector: *Injector` - DI container
- `format: OutputFormat` - Output format (.auto, .json, .yaml)

**Methods:**

```zig
ctx.parse(T: type, s: []const u8) !T
```

Parses string to type T.

```zig
ctx.output(value: anytype) !void
```

Outputs value according to format setting.

## Output Format

**Strings:** Printed as-is
```zig
fn handler() []const u8 { return "Hello"; }
```
```
$ myapp handler
Hello
```

**Structs:** Serialized to JSON or YAML
```zig
fn handler() User { return user; }
```
```
$ myapp handler
id: 123
name: John

$ myapp --json handler
{"id": 123, "name": "John"}
```

**Errors:** Formatted as error objects
```zig
fn handler() !void { return error.Failed; }
```
```
$ myapp handler
error: Failed

$ myapp --json handler
{"error": "Failed"}
```

**void:** No output

## Usage Information

Automatic help display when no command provided or invalid command:

```
Usage: myapp [--json|--yaml] <command> [args...]

Options:
  --json               Output in JSON format
  --yaml               Output in YAML format

Commands:
  version              Show version
  hello                Greet user

Syntax:
  myapp version
  myapp hello <string>
```

## Module Reuse

CLI tools can share DI modules with server applications:

```zig
// Shared module
const AppModule = struct {
    db: Database,
    config: Config,
};

// CLI main
pub fn main() !void {
    const ct = try tk.Container.init(allocator, &.{AppModule});
    defer ct.deinit();

    try tk.cli.run(&ct.injector, allocator, commands);
}
```

Commands automatically have access to all module dependencies.
