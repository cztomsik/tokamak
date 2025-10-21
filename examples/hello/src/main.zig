const std = @import("std");
const tk = @import("tokamak");

// A simple configuration that gets injected into handlers
const Config = struct {
    app_name: []const u8,
    version: []const u8,
    environment: []const u8,

    pub fn init() Config {
        return .{
            .app_name = "Hello World API",
            .version = "1.0.0",
            .environment = "development",
        };
    }
};

// A simple service that can be injected
const GreetingService = struct {
    config: *Config,
    greeting_count: std.atomic.Value(u32) = .init(0),

    pub fn init(config: *Config) GreetingService {
        return .{ .config = config };
    }

    pub fn greet(self: *GreetingService, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        const count = self.greeting_count.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(
            allocator,
            "Hello, {s}! (Greeting #{d} from {s} v{s})",
            .{ name, count + 1, self.config.app_name, self.config.version },
        );
    }
};

const routes: []const tk.Route = &.{
    .get("/", index),
    .get("/hello/:name", hello),
    .get("/stats", stats),
    .get("/config", getConfig),
};

// Simple handler without dependencies
fn index() []const u8 {
    return "Welcome! Try /hello/YourName or /stats";
}

// Handler that injects the greeting service
fn hello(svc: *GreetingService, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return svc.greet(allocator, name);
}

// Handler that reads from the service
fn stats(svc: *GreetingService, allocator: std.mem.Allocator) ![]const u8 {
    const count = svc.greeting_count.load(.monotonic);
    return std.fmt.allocPrint(
        allocator,
        "Total greetings served: {d}",
        .{count},
    );
}

// Handler that injects config directly
fn getConfig(config: *Config) Config {
    return config.*;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize dependencies
    var config = Config.init();
    var greeting_svc = GreetingService.init(&config);

    // Create injector with our dependencies
    var injector = tk.Injector.init(&.{
        .ref(&config),
        .ref(&greeting_svc),
    }, null);

    var server = try tk.Server.init(gpa.allocator(), routes, .{
        .injector = &injector,
    });
    defer server.deinit();

    std.debug.print("Starting {s} v{s} on http://localhost:8080\n", .{
        config.app_name,
        config.version,
    });

    try server.start();
}
