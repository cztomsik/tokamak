# CLI

Command-line interface module for building CLI tools that reuse application dependencies.

## Overview

The CLI module provides basic command parsing and execution. Designed for:

- Companion CLI tools for server applications
- Reusing DI modules, services, and database connections
- Administrative tasks (migrations, imports/exports, backups)

Not intended as a full-featured CLI framework.

## Example

```zig
const std = @import("std");
const tk = @import("tokamak");

const commands = &[_]tk.cli.Command{
    tk.cli.Command.cmd1("hello", "Say hello", hello),
    tk.cli.Command.cmd0("version", "Show version", version),
};

fn hello(name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
}

fn version() []const u8 {
    return "1.0.0";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var injector = tk.Injector.init(&.{}, null);
    try tk.cli.run(&injector, gpa.allocator(), commands);
}
```

Usage:
```bash
$ myapp hello World
Hello, World!

$ myapp version
1.0.0
```

## Command Definitions

Commands are created using helper functions based on argument count:

```zig
// No arguments
tk.cli.Command.cmd0("version", "Show version", getVersion)

// One argument
tk.cli.Command.cmd1("greet", "Greet someone", greet)

// Two arguments
tk.cli.Command.cmd2("add-user", "Add a user", addUser)

// Three arguments
tk.cli.Command.cmd3("create-post", "Create post", createPost)
```

For more than 3 arguments, use the generic `cmd()`:

```zig
tk.cli.Command.cmd("complex", "Complex command", complexFn, 5)
```

## Dependency Injection

Commands inject dependencies via the DI container:

```zig
const commands = &[_]tk.cli.Command{
    tk.cli.Command.cmd1("find-user", "Find user by ID", findUser),
};

fn findUser(db: *Database, id: []const u8) !User {
    return db.findById(User, id);
}

pub fn main() !void {
    var db = try Database.open("app.db");
    defer db.close();

    var injector = tk.Injector.init(&.{ .ref(&db) }, null);
    try tk.cli.run(&injector, gpa.allocator(), commands);
}
```

## Output Formats

The CLI supports multiple output formats:

### Automatic Format (default)

Strings are printed as-is, other types as YAML:

```bash
$ myapp hello World
Hello, World!

$ myapp get-user 123
id: 123
name: John Doe
email: john@example.com
```

### JSON Output

```bash
$ myapp --json get-user 123
{
  "id": 123,
  "name": "John Doe",
  "email": "john@example.com"
}
```

### YAML Output

```bash
$ myapp --yaml get-user 123
id: 123
name: John Doe
email: john@example.com
```

## CLI Context

Commands can access the CLI context for advanced features:

```zig
fn interactiveCommand(ctx: *tk.cli.Context) !void {
    try ctx.out.print("Enter your name: ", .{});
    const input = try ctx.in.readLine();
    try ctx.output(.{ .greeting = input });
}
```

The context provides:

- `arena` - Request-scoped allocator
- `args` - Remaining command arguments
- `in` / `out` / `err` - Standard I/O streams
- `injector` - DI container
- `format` - Output format setting
- `parse(T, str)` - Parse string to type
- `output(value)` - Output value with format

## Optional Arguments

Commands support optional arguments using Zig's optional types:

```zig
fn greet(name: []const u8, title: ?[]const u8) ![]const u8 {
    if (title) |t| {
        return std.fmt.allocPrint(allocator, "Hello, {s} {s}!", .{ t, name });
    }
    return std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
}

const commands = &[_]tk.cli.Command{
    tk.cli.Command.cmd("greet", "Greet someone", greet, 2),
};
```

```bash
$ myapp greet Alice
Hello, Alice!

$ myapp greet Alice Dr.
Hello, Dr. Alice!
```

## Reusing App Modules

Share your server application's configuration and services:

```zig
// shared.zig
const AppModule = struct {
    db: Database,
    config: Config,
    email: EmailService,
};

// server.zig
pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{ AppModule });
}

// cli.zig
const commands = &[_]tk.cli.Command{
    tk.cli.Command.cmd1("send-email", "Send email", sendEmail),
    tk.cli.Command.cmd0("migrate", "Run migrations", runMigrations),
};

fn sendEmail(email: *EmailService, to: []const u8) !void {
    try email.send(to, "Subject", "Body");
}

fn runMigrations(db: *Database) !void {
    try db.migrate();
}

pub fn main() !void {
    const ct = try tk.Container.init(allocator, &.{ AppModule });
    defer ct.deinit();

    try tk.cli.run(&ct.injector, allocator, commands);
}
```

## Built-in Help

The CLI automatically provides usage information:

```bash
$ myapp
Usage: myapp [--json|--yaml] <command> [args...]

Options:
  --json               Output in JSON format
  --yaml               Output in YAML format

Commands:
  hello                Say hello to someone
  version              Show version

Syntax:
  myapp hello <string>
  myapp version
```

## Error Handling

Errors are automatically formatted and displayed:

```zig
fn riskyCommand() !void {
    return error.DatabaseConnectionFailed;
}
```

```bash
$ myapp risky
error: DatabaseConnectionFailed

$ myapp --json risky
{
  "error": "DatabaseConnectionFailed"
}
```

## Real-World Examples

### Database Migration Tool

```zig
const commands = &[_]tk.cli.Command{
    tk.cli.Command.cmd0("migrate", "Run migrations", migrate),
    tk.cli.Command.cmd0("rollback", "Rollback last migration", rollback),
    tk.cli.Command.cmd0("seed", "Seed database", seed),
};

fn migrate(db: *Database) !void {
    try db.runMigrations();
}
```

### Data Export Tool

```zig
const commands = &[_]tk.cli.Command{
    tk.cli.Command.cmd1("export", "Export data", exportData),
};

fn exportData(db: *Database, table: []const u8) ![]Row {
    return db.query(Row, "SELECT * FROM {s}", .{table});
}
```

```bash
$ myapp --json export users > users.json
$ myapp --yaml export products > products.yaml
```

### Admin Tasks

```zig
const commands = &[_]tk.cli.Command{
    tk.cli.Command.cmd2("create-user", "Create user", createUser),
    tk.cli.Command.cmd1("reset-password", "Reset password", resetPassword),
};

fn createUser(db: *Database, email: []const u8, name: []const u8) !User {
    return db.create(User, .{ .email = email, .name = name });
}
```

```bash
$ myapp create-user john@example.com "John Doe"
id: 42
email: john@example.com
name: John Doe
```
