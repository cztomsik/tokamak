const std = @import("std");
const Route = @import("../route.zig").Route;
const Params = @import("../route.zig").Params;
const Context = @import("../context.zig").Context;
const getErrorStatus = @import("../context.zig").getErrorStatus;
const Schema = @import("../schema.zig").Schema;

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

const SchemaOptions = struct {
    info: struct {
        title: []const u8,
        version: []const u8 = "1.0.0",
    },
    routes: ?[]const Route = null,
};

pub fn json(options: SchemaOptions) Route {
    const H = struct {
        fn handler(ctx: *Context) anyerror!void {
            var paths: PathMap = .{};
            try walk(ctx.allocator, "", &paths, options.routes orelse ctx.server.routes);

            try ctx.send(.{
                .openapi = "3.0.0",
                .info = options.info,
                .paths = paths,
            });
        }
    };

    return .{
        .handler = &H.handler,
    };
}

fn walk(arena: std.mem.Allocator, prefix: []const u8, res: *PathMap, routes: []const Route) !void {
    for (routes) |route| {
        if (route.prefix) |p| {
            try walk(arena, try std.mem.concat(arena, u8, &.{ prefix, p }), res, route.children);
        } else {
            try walk(arena, prefix, res, route.children);

            if (route.method) |met| {
                const m = route.metadata orelse continue;
                const key = try swaggerPath(arena, prefix, route.path orelse continue);
                const path = (try res.map.getOrPutValue(arena, key, .{})).value_ptr;

                var op: Operation = .{};

                if (m.params.len > 0) {
                    var params = std.ArrayList(Parameter).init(arena);
                    const names = Params.match(route.path.?, route.path.?).?;

                    for (m.params, 0..) |schema, i| try params.append(.{
                        .name = names.matches[i][1..],
                        .in = "path",
                        .required = true,
                        .schema = schema,
                    });

                    op.parameters = params.items;
                }

                if (m.body) |schema| {
                    op.requestBody = .{
                        .content = .{
                            .map = try .init(arena, &.{"application/json"}, &.{.{ .schema = schema }}),
                        },
                    };
                }

                if (m.result) |schema| {
                    try op.responses.map.put(arena, "200", .{
                        .description = null,
                        .content = .{
                            .map = try .init(arena, &.{"application/json"}, &.{.{ .schema = schema }}),
                        },
                    });
                }

                for (m.errors) |e| {
                    const status = try std.fmt.allocPrint(arena, "{d}", .{getErrorStatus(e)});
                    try op.responses.map.put(arena, status, .{
                        .description = @errorName(e),
                        .content = null,
                    });
                }

                try path.map.put(
                    arena,
                    try std.ascii.allocLowerString(arena, @tagName(met)),
                    op,
                );
            }
        }
    }
}

fn swaggerPath(arena: std.mem.Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    var res = std.ArrayList(u8).init(arena);
    try res.appendSlice(prefix);

    var pos: usize = 0;
    while (pos < path.len) {
        if (pos > 0) {
            try res.append('/');
        }

        const colon = std.mem.indexOfScalarPos(u8, path, pos, ':') orelse {
            try res.appendSlice(path[pos..]);
            break;
        };

        const slash = std.mem.indexOfScalarPos(u8, path, colon, '/') orelse path.len;

        try res.appendSlice(path[pos..colon]);
        try res.append('{');
        try res.appendSlice(path[colon + 1 .. slash]);
        try res.append('}');
        pos = slash;
    }

    return res.items;
}

const PathMap = std.json.ArrayHashMap(Path);
const Path = std.json.ArrayHashMap(Operation);
const Operation = struct { parameters: []const Parameter = &.{}, requestBody: ?RequestBody = null, responses: std.json.ArrayHashMap(Response) = .{} };
const Parameter = struct { name: []const u8, in: []const u8, required: bool, schema: Schema };
const RequestBody = struct { content: std.json.ArrayHashMap(Content) };
const Response = struct { description: ?[]const u8, content: ?std.json.ArrayHashMap(Content) };
const Content = struct { schema: Schema };
