const std = @import("std");
const httpz = @import("httpz");

pub const config = @import("config.zig");
pub const cron = @import("cron.zig");
pub const monitor = @import("monitor.zig").monitor;

pub const Injector = @import("injector.zig").Injector;
pub const TypeId = @import("injector.zig").TypeId;
pub const Factory = @import("factory.zig").Factory;

pub const Server = @import("server.zig").Server;
pub const ServerOptions = @import("server.zig").InitOptions;
pub const ListenOptions = @import("server.zig").ListenOptions;
pub const Route = @import("route.zig").Route;
pub const Context = @import("context.zig").Context;
pub const Handler = @import("context.zig").Handler;
pub const Request = httpz.Request;
pub const Response = httpz.Response;

pub const cors = @import("middleware/cors.zig").cors;
pub const logger = @import("middleware/logger.zig").logger;
pub const static = @import("middleware/static.zig");

// TODO: split/avoid usingnamespace
pub usingnamespace @import("middleware.zig");

test {
    std.testing.refAllDecls(@This());
}
