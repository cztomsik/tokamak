# hello_cli

A comprehensive CLI application demonstrating various commands and third-party integrations.

## Source Code

**Path:** `examples/hello_cli/`

## Features Demonstrated

- CLI command framework (`tk.cli`)
- HTTP client integration
- HTML to Markdown conversion
- DOM parsing and querying
- PDF generation
- Regular expressions and grep functionality
- GitHub API integration
- Hacker News API integration

## Available Commands

### `hello`
Print a greeting message.

```sh
zig build run -- hello
```

### `hn <limit>`
Show top Hacker News stories.

```sh
zig build run -- hn 5
```

### `gh <owner>`
List GitHub repositories for a user.

```sh
zig build run -- gh cztomsik
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

### `pdf <filename> <title>`
Generate a sample PDF with various shapes and text.

```sh
zig build run -- pdf output.pdf "My Document"
```

## Architecture

The CLI uses a shared `App` struct for services (HTTP client, API clients) and a `Cli` struct for command definitions:

```zig
const App = struct {
    http_client: tk.http.StdClient,
    hn_client: tk.hackernews.Client,
};

const Cli = struct {
    cmds: []const tk.cli.Command = &.{
        .usage,
        .cmd0("hello", "Print a greeting message", hello),
        .cmd1("hn", "Show top Hacker News stories", hn_top),
        // ...
    },
};
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

## Next Steps

- See [clown-commander](./clown-commander.md) for a TUI application
- Check out [hello_ai](./hello_ai.md) for AI agent integration
