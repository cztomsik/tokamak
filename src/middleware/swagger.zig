const std = @import("std");
const Route = @import("../route.zig").Route;
const Context = @import("../context.zig").Context;

const Options = struct {
    info: struct {
        title: []const u8,
        version: []const u8 = "1.0.0",
    },
    routes: ?[]const Route = null,
};

pub fn json(options: Options) Route {
    const H = struct {
        fn handler(ctx: *Context) anyerror!void {
            try ctx.send(.{
                .openapi = "3.0.0",
                .info = options.info,
                .paths = try paths(ctx.allocator, options.routes orelse ctx.server.routes),
            });
        }
    };

    return .{
        .handler = &H.handler,
    };
}

const UiOptions = struct {
    url: []const u8,
};

pub fn ui(options: UiOptions) Route {
    const H = struct {
        fn handler(ctx: *Context) anyerror!void {
            const header =
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\  <title>Swagger UI</title>
                \\  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/5.17.14/swagger-ui.css" />
                \\</head>
                \\<body>
                \\  <div id="swagger-ui"></div>
                \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/5.17.14/swagger-ui-bundle.js"></script>
                \\  <script>
            ;

            const footer =
                \\    SwaggerUIBundle({ ...config, dom_id: "#swagger-ui"})
                \\  </script>
                \\</body>
                \\</html>
            ;

            ctx.res.content_type = .HTML;
            ctx.res.body = try std.fmt.allocPrint(ctx.allocator, "{s}\nconst config = {}\n{s}", .{ header, std.json.fmt(options, .{}), footer });
            ctx.responded = true;
        }
    };

    return .{
        .handler = &H.handler,
    };
}

fn paths(arena: std.mem.Allocator, routes: []const Route) !PathMap {
    var res: PathMap = .{};
    try walk(arena, "", &res, routes);
    return res;
}

fn walk(arena: std.mem.Allocator, prefix: []const u8, res: *PathMap, routes: []const Route) !void {
    for (routes) |route| {
        if (route.prefix) |p| {
            try walk(arena, try std.mem.concat(arena, u8, &.{ prefix, p }), res, route.children);
        } else {
            try walk(arena, prefix, res, route.children);

            if (route.method) |m| {
                // TODO: translatePath(arena, prefix, path) which will replace :id with {id}
                const key = try std.mem.concat(arena, u8, &.{ prefix, route.path orelse continue });

                if (!res.map.contains(key)) {
                    try res.map.put(arena, p, .{});
                }

                const path = res.map.getPtr(key).?;

                try path.map.put(arena, try std.ascii.allocLowerString(arena, @tagName(m)), .{
                    .parameters = &.{}, // TODO: route.meta.params
                    // TODO: route.meta.body_schema
                    .responses = &.{}, // TODO: route.meta.response_schema
                });
            }
        }
    }
}

const PathMap = std.json.ArrayHashMap(Path);
const Path = std.json.ArrayHashMap(Operation);
const Operation = struct { parameters: []const Parameter, responses: []const Response };
const Parameter = struct { name: []const u8, in: []const u8, required: bool, schema: Schema };
const Response = struct {};
const Schema = struct {};
