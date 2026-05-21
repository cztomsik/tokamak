# Tokamak — Zig Web Framework

## System Environment

- **zig** 0.15.2 (`/Users/cztomsik/.zvm/bin/zig`)
- **node** v24.14.1 (`/Users/cztomsik/.nvm/versions/node/v24.14.1/bin/node`)
- **python3** 3.9.6 (`/usr/bin/python3`)
- **rg** (ripgrep) 15.1.0 — use for quick navigation: `rg -o '^\s*(pub )?(fn|struct|const|var|test)\s+\w+' .`
- **jq** 1.8.1
- Quick computations: `python3 -c 'print(2+2)'`

## Project Overview

**Tokamak** is a web application framework for Zig (v0.15.2), built around [http.zig](https://github.com/karlseguin/http.zig) and a dependency injection container. It is designed to run behind a reverse proxy (Nginx, CloudFront) for SSL, caching, and sanitization.

- **Version:** 2.0.0
- **Dependency:** `httpz` (git hash `00014146eaf9e17750b752fa4905f7623fbe30f7`)
- **Build command:** `zig build`
- **Test command:** `zig build test` (optionally with `--filter <pattern>`)
- **Docs build:** `npm run docs:build` (in `docs/`)

## Key Concepts

- **Dependency Injection** — Handler functions receive injected parameters (allocator, `*Request`, `*Response`, custom types). The `Container`/`Bundle` system resolves dependencies across modules at runtime.
- **Routing** — Express-inspired router with path params (`:name`), wildcards (`*`), nested routes, and middleware via `ctx.next()`.
- **Multi-Module System** — Structs with fields become modules; fields are auto-resolved as dependencies. Supports `configure(bundle)` hooks, overrides, mocks, and lifecycle hooks.
- **Serde** — Custom serialization system with `T.serialize(writer)` hooks; deserialization (`deserialize`) is WIP (see `DESER.md`).
- **TUI Module** — WIP terminal UI framework in `tk.tui.*`.
- **AI Module** — WIP LLM client/agent framework in `tk.ai.*`.

## Source Structure

| File / Directory | Purpose |
|---|---|
| `src/main.zig` | Root module — re-exports all public namespaces, core types (`Injector`, `Container`, `Bundle`, `Server`, `Route`, `Context`, `Schema`), and middlewares. |
| `src/server.zig` | `Server` — HTTP server wrapper around httpz, handles initialization and lifecycle. |
| `src/route.zig` | `Route` — hierarchical route definitions with `get`, `post`, `group`, `send`, `redirect`, `router(T)`. |
| `src/context.zig` | `Context` — request context with `next()`, `nextScoped()`, event streaming, middleware chain. |
| `src/injector.zig` | `Injector` — core DI container, resolves and calls functions with injected parameters. |
| `src/container.zig` | `Container` + `Bundle` — advanced multi-module DI with `provide()`, `override()`, `mock()`, `expose()`, init/deinit hooks. |
| `src/app.zig` | `app` namespace — high-level app runner, ties Container + Server together. |
| `src/schema.zig` | `Schema` — request validation schema builder. |
| `src/middleware/` | Built-in middlewares: `cors.zig`, `logger.zig`, `static.zig`, `swagger.zig`. |
| `src/serde.zig` | Custom serialization framework — `serialize(writer, value)` with format-specific writers (JSON, YAML, CSV, table). |
| `src/serde/` | Format-specific serializers: `json.zig`, `yaml.zig`, `csv.zig`, `table.zig`. |
| `src/dom/` | DOM implementation — `document.zig`, `element.zig`, `node.zig`, `parser.zig`, `text.zig`, `local_name.zig`. |
| `src/tui/` | WIP Terminal UI — `builder.zig`, `color.zig`, `context.zig`, `control.zig`, `frame.zig`, `input.zig`, `screen.zig`, `widgets.zig`. |
| `src/ai/` | WIP AI/LLM module — `agent.zig`, `chat.zig`, `client.zig`, `embedding.zig`, `fmt.zig`, `models.zig`. |
| `src/http/` | HTTP client wrapper around httpz — `client.zig`. |
| `src/tpl.zig` | Template engine. |
| `src/ssr.zig` | Server-side rendering utilities. |
| `src/js.zig` | JavaScript interop / utilities. |
| `src/vm.zig` | Virtual machine / sandbox utilities. |
| `src/cron.zig` | Cron scheduler. |
| `src/queue.zig` | Job queue system. |
| `src/monitor.zig` | Process monitor — runs multiple processes with auto-restart. |
| `src/cli.zig` | CLI argument parsing and command runner. |
| `src/config.zig` | JSON config file reader/writer. |
| `src/crypto.zig` | Cryptographic utilities. |
| `src/entities.zig` | HTML entity encoding/decoding. |
| `src/event.zig` | Event system. |
| `src/ext/` | External API integrations: `github.zig`, `hackernews.zig`, `reddit.zig`. |
| `src/html2md.zig` | HTML-to-Markdown converter. |
| `src/iter.zig` | Iterator utilities. |
| `src/meta.zig` | Meta utilities (introspection helpers). |
| `src/mime.zig` | MIME type mappings. |
| `src/parse.zig` | General parsing utilities. |
| `src/pdf.zig` | PDF generation utilities. |
| `src/regex.zig` | Regex utilities. |
| `src/resource.zig` | Resource management. |
| `src/sax.zig` | SAX-style XML/HTML parser. |
| `src/selector.zig` | CSS-like selector engine for DOM. |
| `src/sendmail.zig` | Email sending. |
| `src/string.zig` | `String` and `ShortString` types. |
| `src/testing.zig` | Testing utilities. |
| `src/time.zig` | Time/date utilities. |
| `src/util/` | Utility modules: `bptree.zig`, `buf.zig`, `shm.zig`, `slotmap.zig`, `sparse.zig`. |
| `src/util.zig` | Top-level utility re-exports. |

## Architecture Notes

- **httpz** is the sole external dependency, imported as `httpz` in the build system. All HTTP handling flows through it.
- **DI flow**: `Container.init(allocator, modules)` → resolves dependencies via `Bundle.configure()` hooks → populates `Injector` → `Server` uses the injector to call handlers.
- **Route hierarchy**: Routes can nest children, enabling middleware patterns. `ctx.next()` continues the chain. `ctx.nextScoped()` adds request-scoped dependencies.
- **Serialization**: Values returned from handlers that aren't `[]const u8` are auto-serialized to JSON via `T.serialize()`. Custom hooks override default behavior.
- **Static files**: Served via `tk.static.file(path)` or `tk.static.dir(path)`. Files can be embedded at compile time via `tokamak.setup(exe, .{.embed = &.{...}})`.
- **Testing**: `zig build test` runs all tests. Filters supported via `--filter`. The main module test block auto-reflexes all exported structs.
- **Docs**: Static site generator in `docs/` using Preact + marked. Build with `npm run docs:build`.
- **Examples**: Located in `examples/` — `hello`, `hello_app`, `hello_cli`, `hello_ssr`, `hello_tui`, `blog`, `todos_orm_sqlite`, `clown-commander`, `webview_app`, `hello_objc`, `src/`.
