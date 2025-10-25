# API Reference

This section contains detailed API documentation for all Tokamak modules. For tutorials and guides, see the [Guide](/guide/getting-started) section.

## Core Framework

### [Server](/reference/server)
HTTP server implementation with dependency injection integration. Built on top of http.zig for high-performance request handling.

### [Routing](/reference/routing)
Express-inspired routing system with path parameters, wildcards, and nested routes.

### [Dependency Injection](/reference/dependency-injection)
Compile-time dependency injection container with automatic resolution and lifecycle management.

## Command-Line Interface

### [CLI](/reference/cli)
Type-safe CLI framework with automatic argument parsing and dependency injection.

### [TUI](/reference/tui)
Terminal UI components for building interactive command-line applications.

## Utilities

### [Time](/reference/time)
Rata Die-based calendar library for date and time manipulation with UTC support.

### [Process Monitoring](/reference/monitoring)
Monitoring and observability utilities for tracking application health and performance.
