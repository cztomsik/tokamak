# hello_cli

A comprehensive CLI application demonstrating various commands and third-party integrations.

## Source Code

**Path:** `examples/hello_cli/`

```zig
@include examples/hello_cli/src/main.zig
```

## Features Demonstrated

- CLI command framework (`tk.cli`)
- HTTP client integration
- HTML to Markdown conversion
- DOM parsing and querying
- Regular expressions and grep functionality

## Available Commands

### `hello`
Print a greeting message.

```sh
zig build run -- hello
```

### `scrape <url> [selector]`
Scrape a URL and convert to Markdown, with optional CSS selector.

```sh
zig build run -- scrape https://example.com
zig build run -- scrape https://example.com "article.content"
```

### `grep <file> <pattern>`
Search for a regex pattern in a file.

```sh
zig build run -- grep myfile.txt "TODO.*"
```

### `substr <str> [start] [end]`
Get substring with bounds checking.

```sh
zig build run -- substr "Hello World" 0 5
```

## Architecture

The CLI uses a shared `App` struct for services (HTTP client, API clients) and a `Cli` struct for command definitions:

```zig
@include examples/hello_cli/src/main.zig#L5-L17
```

## Command Handler Patterns

Handlers can inject dependencies:
- `arena: std.mem.Allocator` - Per-command arena allocator
- Service dependencies (e.g., `*tk.http.Client`)
- Command arguments as function parameters

## Running

```sh
cd examples/hello_cli
zig build run -- <command> [args...]
```

