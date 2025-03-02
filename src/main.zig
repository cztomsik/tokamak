const std = @import("std");
const httpz = @import("httpz");

pub const app = @import("app.zig");
pub const config = @import("config.zig");
pub const cron = @import("cron.zig");
pub const crypto = @import("crypto.zig");
pub const meta = @import("meta.zig");
pub const monitor = @import("monitor.zig").monitor;
pub const sax = @import("sax.zig");
pub const tpl = @import("tpl.zig");

pub const Injector = @import("injector.zig").Injector;
pub const Module = @import("module.zig").Module;

pub const Server = @import("server.zig").Server;
pub const ServerOptions = @import("server.zig").InitOptions;
pub const ListenOptions = @import("server.zig").ListenOptions;
pub const Route = @import("route.zig").Route;
pub const Context = @import("context.zig").Context;
pub const Handler = @import("context.zig").Handler;
pub const EventStream = @import("context.zig").EventStream;
pub const Schema = @import("schema.zig").Schema;
pub const Request = httpz.Request;
pub const Response = httpz.Response;

// Middlewares
pub const cors = @import("middleware/cors.zig").cors;
pub const logger = @import("middleware/logger.zig").logger;
pub const static = @import("middleware/static.zig");
pub const swagger = @import("middleware/swagger.zig");

// Shorthands
pub const send = Route.send;
pub const redirect = Route.redirect;

test {
    std.testing.refAllDecls(@This());
}
