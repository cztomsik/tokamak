const std = @import("std");
const tk = @import("tokamak");

// Configuration module that can be shared across the app
const ConfigModule = struct {
    config: Config,

    const Config = struct {
        app_name: []const u8 = "Hello App",
        version: []const u8 = "1.0.0",
        port: u16 = 8080,
        debug: bool = true,
    };
};

// Shared services module
const ServicesModule = struct {
    logger: Logger,
    metrics: Metrics,

    // Simple logger that can be injected
    const Logger = struct {
        debug_enabled: bool,

        pub fn init(config: *ConfigModule.Config) Logger {
            return .{ .debug_enabled = config.debug };
        }

        pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
            std.debug.print("[INFO] " ++ fmt ++ "\n", args);
            _ = self;
        }

        pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
            if (self.debug_enabled) {
                std.debug.print("[DEBUG] " ++ fmt ++ "\n", args);
            }
        }
    };

    // Simple metrics tracker
    const Metrics = struct {
        requests: std.atomic.Value(u64) = .init(0),
        errors: std.atomic.Value(u64) = .init(0),

        pub fn init() Metrics {
            return .{};
        }

        pub fn recordRequest(self: *Metrics) void {
            _ = self.requests.fetchAdd(1, .monotonic);
        }

        pub fn recordError(self: *Metrics) void {
            _ = self.errors.fetchAdd(1, .monotonic);
        }

        pub fn getStats(self: *Metrics) Stats {
            return .{
                .requests = self.requests.load(.monotonic),
                .errors = self.errors.load(.monotonic),
            };
        }

        const Stats = struct {
            requests: u64,
            errors: u64,
        };
    };

    pub fn configure(bundle: *tk.Bundle) void {
        // Add init hook to log when services are ready
        bundle.addInitHook(logServicesReady);
    }

    fn logServicesReady(logger: *Logger) void {
        logger.info("Services initialized", .{});
    }
};

// Web module with routes and handlers
const WebModule = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{
        // Middleware to track metrics
        .handler(metricsMiddleware),
        .get("/", index),
        .get("/hello/:name", hello),
        .get("/health", health),
        .get("/metrics", getMetrics),
    },

    fn metricsMiddleware(ctx: *tk.Context, metrics: *ServicesModule.Metrics) !void {
        metrics.recordRequest();
        return ctx.next();
    }

    fn index(config: *ConfigModule.Config) []const u8 {
        _ = config;
        return "Welcome! Try /hello/YourName, /health, or /metrics";
    }

    fn hello(
        logger: *ServicesModule.Logger,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ![]const u8 {
        logger.debug("Greeting user: {s}", .{name});
        return std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    }

    fn health(
        config: *ConfigModule.Config,
        metrics: *ServicesModule.Metrics,
    ) struct {
        status: []const u8,
        app: []const u8,
        version: []const u8,
        requests: u64,
    } {
        const stats = metrics.getStats();
        return .{
            .status = "ok",
            .app = config.app_name,
            .version = config.version,
            .requests = stats.requests,
        };
    }

    fn getMetrics(metrics: *ServicesModule.Metrics) ServicesModule.Metrics.Stats {
        return metrics.getStats();
    }

    pub fn configure(bundle: *tk.Bundle) void {
        // Add init hook to print server info
        bundle.addInitHook(printServerInfo);
    }

    fn printServerInfo(config: *ConfigModule.Config, logger: *ServicesModule.Logger) void {
        logger.info("Starting {s} v{s} on http://localhost:{d}", .{
            config.app_name,
            config.version,
            config.port,
        });
    }
};

pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{
        ConfigModule,
        ServicesModule,
        WebModule,
    });
}
