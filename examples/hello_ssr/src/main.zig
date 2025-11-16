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

const Badge = struct {
    label: []const u8,
    variant: enum { primary, success, warning, danger } = .primary,

    pub fn render(self: *@This(), ctx: *tk.ssr.RenderContext) !void {
        const class = switch (self.variant) {
            .primary => "bg-blue-600 text-white px-2 py-1 rounded text-xs ml-2",
            .success => "bg-green-600 text-white px-2 py-1 rounded text-xs ml-2",
            .warning => "bg-yellow-600 text-white px-2 py-1 rounded text-xs ml-2",
            .danger => "bg-red-600 text-white px-2 py-1 rounded text-xs ml-2",
        };
        try ctx.open("span", &.{.{ "class", class }});
        try ctx.text(self.label);
        try ctx.close("span");
    }
};

const Card = struct {
    title: []const u8,

    pub fn render(self: *@This(), ctx: *tk.ssr.RenderContext) !void {
        try ctx.raw("<div class=\"border border-gray-300 rounded-lg p-5 my-5\">");
        try ctx.raw("<h2 class=\"text-xl font-semibold mb-4\">");
        try ctx.text(self.title);
        try ctx.raw("</h2></div>");
    }
};

const UserRow = struct {
    name: []const u8,
    email: []const u8,
    is_admin: bool = false,

    pub fn render(self: *@This(), ctx: *tk.ssr.RenderContext) !void {
        try ctx.raw("<div class=\"p-2.5 border-b border-gray-200 last:border-b-0\"><strong>");
        try ctx.text(self.name);
        try ctx.raw("</strong> - ");
        try ctx.text(self.email);

        if (self.is_admin) {
            try ctx.raw("<span class=\"bg-blue-600 text-white px-2 py-1 rounded text-xs ml-2\">Admin</span>");
        }

        try ctx.raw("</div>");
    }
};

const Counter = struct {
    count: i32,
    label: []const u8 = "Items",

    pub fn render(self: *@This(), ctx: *tk.ssr.RenderContext) !void {
        try ctx.raw("<div class=\"text-gray-600 mb-4\">");
        try ctx.text(self.label);
        try ctx.print(": {}", .{self.count});
        try ctx.raw("</div>");
    }
};

const App = struct {
    loader: tk.resource.FsLoader,
    tpl: tk.ssr.DefaultEngine,
    server: tk.Server,
    routes: []const tk.Route = &.{
        .get("/", home),
    },

    pub fn configure(bundle: *tk.Bundle) void {
        bundle.addInitHook(defineComponents);
    }

    fn defineComponents(engine: *tk.ssr.DefaultEngine) !void {
        try engine.defineComponent("badge", Badge);
        try engine.defineComponent("card", Card);
        try engine.defineComponent("user-row", UserRow);
        try engine.defineComponent("counter", Counter);
    }

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
