const std = @import("std");
const httpz = @import("httpz");

// Stand-alone namespaces
pub const app = @import("app.zig");
// pub const cdp = @import("cdp.zig");
// pub const client = @import("client.zig");
pub const config = @import("config.zig");
// pub const cron = @import("cron.zig");
pub const crypto = @import("crypto.zig");
pub const csv = @import("csv.zig");
pub const event = @import("event.zig");
// pub const mail = @import("mail.zig");
pub const meta = @import("meta.zig");
pub const monitor = @import("monitor.zig").monitor;
// pub const openai = @import("openai.zig");
pub const sax = @import("sax.zig");
pub const tpl = @import("tpl.zig");

// Core types (DI)
pub const Injector = @import("injector.zig").Injector;
pub const Container = @import("container.zig").Container;

// Core types (Server)
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
