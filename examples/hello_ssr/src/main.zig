const std = @import("std");
const tk = @import("tokamak");

const Config = struct {
    loader: tk.resource.FsLoaderOptions = .{},
};

const Html = struct {
    content: []const u8,

    pub fn sendResponse(self: @This(), ctx: *tk.Context) !void {
        ctx.res.content_type = .HTML;
        ctx.res.body = self.content;
    }
};

const App = struct {
    loader: tk.resource.FsLoader,
    tpl: tk.ssr.DefaultEngine,
    server: tk.Server,
    routes: []const tk.Route = &.{
        .get("/", home),
    },

    fn home(tpl: *tk.ssr.Engine, arena: std.mem.Allocator) !Html {
        const html = try tpl.render("templates/home.html", arena, .{
            .title = "SSR Demo",
            .users = &[_]struct { name: []const u8, email: []const u8, admin: bool }{
                .{ .name = "Bob", .email = "bob@example.com", .admin = true },
                .{ .name = "Charlie", .email = "charlie@example.com", .admin = false },
                .{ .name = "Diana", .email = "diana@example.com", .admin = false },
            },
        });

        return .{ .content = html };
    }
};

pub fn main() !void {
    try tk.app.run(tk.Server.start, &.{ Config, App });
}
