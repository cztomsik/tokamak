const std = @import("std");
const httpz = @import("httpz");

// Stand-alone namespaces
pub const ai = @import("ai.zig");
pub const ansi = @import("ansi.zig");
pub const app = @import("app.zig");
// pub const cdp = @import("cdp.zig");
pub const config = @import("config.zig");
pub const cron = @import("cron.zig");
pub const crypto = @import("crypto.zig");
pub const csv = @import("csv.zig");
pub const dom = @import("dom.zig");
pub const entities = @import("entities.zig");
pub const event = @import("event.zig");
pub const hackernews = @import("hackernews.zig");
pub const http = @import("http.zig");
pub const github = @import("github.zig");
// pub const mail = @import("mail.zig");
pub const mem = @import("mem.zig");
pub const meta = @import("meta.zig");
pub const monitor = @import("monitor.zig").monitor;
pub const queue = @import("queue.zig");
pub const reddit = @import("reddit.zig");
pub const regex = @import("regex.zig");
pub const sax = @import("sax.zig");
pub const selector = @import("selector.zig");
pub const sendmail = @import("sendmail.zig");
pub const testing = @import("testing.zig");
pub const tpl = @import("tpl.zig");
pub const util = @import("util.zig");

// Core types (DI)
pub const Injector = @import("injector.zig").Injector;
pub const Container = @import("container.zig").Container;
pub const Bundle = @import("container.zig").Bundle;

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
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        if (comptime @TypeOf(@field(@This(), decl.name)) == type and meta.isStruct(@field(@This(), decl.name))) {
            std.testing.refAllDecls(@field(@This(), decl.name));
        }
    }
}
