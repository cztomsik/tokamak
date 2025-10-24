const std = @import("std");
const resource = @import("resource.zig");
const sax = @import("sax.zig");
const js = @import("js.zig");
const vm = @import("vm.zig");

pub const Engine = struct {
    pub const VTable = struct {
        render: *const fn (*Engine, []const u8, std.mem.Allocator, vm.Value) anyerror![]const u8,
    };

    vtable: *const VTable,

    pub fn render(self: *Engine, name: []const u8, arena: std.mem.Allocator, data: anytype) ![]const u8 {
        const value = vm.Value.from(data);
        return self.vtable.render(self, name, arena, value);
    }
};

pub const DefaultEngine = struct {
    loader: *resource.Loader,
    interface: Engine = .{ .vtable = &.{ .render = &render } },

    fn render(engine: *Engine, name: []const u8, arena: std.mem.Allocator, data: vm.Value) ![]const u8 {
        const self: *DefaultEngine = @fieldParentPtr("interface", engine);

        const res = try self.loader.load(arena, name) orelse return error.TemplateNotFound;
        const template = try Template.parse(arena, res.content);
        return template.render(arena, data);
    }
};

// pub const MustacheEngine = struct {
//     loader: *resource.Loader,
//     interface: Engine = .{ .vtable = &.{ .render = &render } },

//     fn render(engine: *Engine, name: []const u8, arena: std.mem.Allocator, data: vm.Value) ![]const u8 {
//         const self: *MustacheEngine = @fieldParentPtr("interface", engine);

//         const res = try self.loader.load(arena, name) orelse return error.TemplateNotFound;
//         const template = try mustache.Template.parse(arena, res.content);
//         return template.renderAlloc(arena, data);
//     }
// };

pub const Template = struct {
    root: []Node,
    arena: std.mem.Allocator,

    const Node = union(enum) {
        element: Element,
        text: []const u8,
        interpolation: []const u8,
        conditional: Conditional,
        loop: Loop,
    };

    const Element = struct {
        tag: []const u8,
        attrs: []Attribute,
        children: []Node,
    };

    const Attribute = struct {
        name: []const u8,
        value: []const u8,
    };

    const Conditional = struct {
        condition: []const u8,
        element: Element,
        else_element: ?Element = null,
    };

    const Loop = struct {
        item_name: []const u8,
        array_name: []const u8,
        element: Element,
    };

    pub fn parse(arena: std.mem.Allocator, input: []const u8) !Template {
        var parser = Parser.init(arena);
        defer parser.deinit();

        var sax_parser = sax.Parser.initCompleteInput(input);

        while (try sax_parser.next()) |event| {
            try parser.handleEvent(event);
        }

        return parser.finish();
    }

    pub fn render(self: Template, allocator: std.mem.Allocator, data: anytype) ![]const u8 {
        var aw = std.io.Writer.Allocating.init(allocator);
        defer aw.deinit();

        try self.renderInto(&aw.writer, data);

        return aw.toOwnedSlice();
    }

    pub fn renderInto(self: Template, writer: *std.io.Writer, data: anytype) !void {
        var ctx = try RenderContext.init(self.arena, writer);
        defer ctx.deinit();

        try ctx.setData(data);
        try ctx.renderNodes(self.root);

        try writer.flush();
    }
};

const Parser = struct {
    arena: std.mem.Allocator,
    stack: std.ArrayList(StackItem),
    root_nodes: std.ArrayList(Template.Node),

    const StackItem = struct {
        tag: []const u8,
        attrs: std.ArrayList(Template.Attribute),
        children: std.ArrayList(Template.Node),
    };

    const Directives = struct {
        v_if: ?[]const u8 = null,
        v_else: bool = false,
        v_for: ?[]const u8 = null,
        attrs: std.ArrayList(Template.Attribute),
    };

    fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .arena = allocator,
            .stack = .{},
            .root_nodes = .{},
        };
    }

    fn deinit(self: *Parser) void {
        self.stack.deinit(self.arena);
        self.root_nodes.deinit(self.arena);
    }

    fn handleEvent(self: *Parser, event: sax.Event) !void {
        switch (event) {
            .open => |tag| {
                try self.stack.append(self.arena, .{
                    .tag = try self.arena.dupe(u8, tag),
                    .attrs = .{},
                    .children = .{},
                });
            },

            .attr => |attr| {
                if (self.stack.items.len > 0) {
                    const current = &self.stack.items[self.stack.items.len - 1];
                    try current.attrs.append(self.arena, .{
                        .name = try self.arena.dupe(u8, attr.name),
                        .value = try self.arena.dupe(u8, attr.value),
                    });
                }
            },

            .close => |tag| {
                if (self.stack.items.len == 0) return;
                if (tag.len > 0 and !std.mem.eql(u8, self.stack.items[self.stack.items.len - 1].tag, tag)) return;

                var item = self.stack.pop() orelse unreachable;
                var dirs = try self.extractDirectives(item.attrs.items);
                defer dirs.attrs.deinit(self.arena);

                if (dirs.v_else) {
                    if (try self.attachElse(&item, &dirs)) return;
                }

                const node = try self.createNode(&item, &dirs);
                try self.addNode(node);
            },

            .text => |content| {
                try self.parseTextContent(self.currentChildren(), content);
            },
        }
    }

    fn currentChildren(self: *Parser) *std.ArrayList(Template.Node) {
        if (self.stack.items.len > 0) {
            return &self.stack.items[self.stack.items.len - 1].children;
        }
        return &self.root_nodes;
    }

    fn addNode(self: *Parser, node: Template.Node) !void {
        try self.currentChildren().append(self.arena, node);
    }

    fn extractDirectives(self: *Parser, attrs: []const Template.Attribute) !Directives {
        var dirs: Directives = .{ .attrs = .{} };
        for (attrs) |attr| {
            if (std.mem.eql(u8, attr.name, "v-if")) {
                dirs.v_if = attr.value;
            } else if (std.mem.eql(u8, attr.name, "v-else")) {
                dirs.v_else = true;
            } else if (std.mem.eql(u8, attr.name, "v-for")) {
                dirs.v_for = attr.value;
            } else {
                try dirs.attrs.append(self.arena, attr);
            }
        }
        return dirs;
    }

    fn attachElse(self: *Parser, item: *StackItem, dirs: *Directives) !bool {
        const siblings = self.currentChildren();
        if (siblings.items.len == 0) return error.ParseError;

        const last_idx = siblings.items.len - 1;
        if (siblings.items[last_idx] != .conditional) return error.ParseError;

        siblings.items[last_idx].conditional.else_element = .{
            .tag = item.tag,
            .attrs = try dirs.attrs.toOwnedSlice(self.arena),
            .children = try item.children.toOwnedSlice(self.arena),
        };
        return true;
    }

    fn createNode(self: *Parser, item: *StackItem, dirs: *Directives) !Template.Node {
        const elem = Template.Element{
            .tag = item.tag,
            .attrs = try dirs.attrs.toOwnedSlice(self.arena),
            .children = try item.children.toOwnedSlice(self.arena),
        };

        if (dirs.v_for) |for_expr| {
            const parsed = try self.parseVFor(for_expr);
            return .{ .loop = .{
                .item_name = parsed.item_name,
                .array_name = parsed.array_name,
                .element = elem,
            } };
        }

        if (dirs.v_if) |condition| {
            return .{ .conditional = .{
                .condition = condition,
                .element = elem,
            } };
        }

        return .{ .element = elem };
    }

    fn parseTextContent(self: *Parser, target: *std.ArrayList(Template.Node), content: []const u8) !void {
        var pos: usize = 0;
        while (pos < content.len) {
            const start = std.mem.indexOfPos(u8, content, pos, "{{") orelse {
                try target.append(self.arena, .{ .text = try self.arena.dupe(u8, content[pos..]) });
                break;
            };

            if (start > pos) {
                try target.append(self.arena, .{ .text = try self.arena.dupe(u8, content[pos..start]) });
            }

            const end = std.mem.indexOfPos(u8, content, start + 2, "}}") orelse {
                try target.append(self.arena, .{ .text = try self.arena.dupe(u8, content[start..]) });
                break;
            };

            const expr = std.mem.trim(u8, content[start + 2 .. end], " \t\n\r");
            try target.append(self.arena, .{ .interpolation = try self.arena.dupe(u8, expr) });
            pos = end + 2;
        }
    }

    fn parseVFor(self: *Parser, expr: []const u8) !struct { item_name: []const u8, array_name: []const u8 } {
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        const in_pos = std.mem.indexOf(u8, trimmed, " in ") orelse return error.ParseError;

        return .{
            .item_name = try self.arena.dupe(u8, std.mem.trim(u8, trimmed[0..in_pos], " \t\n\r")),
            .array_name = try self.arena.dupe(u8, std.mem.trim(u8, trimmed[in_pos + 4 ..], " \t\n\r")),
        };
    }

    fn finish(self: *Parser) !Template {
        return .{
            .root = try self.root_nodes.toOwnedSlice(self.arena),
            .arena = self.arena,
        };
    }
};

const RenderContext = struct {
    writer: *std.io.Writer,
    js: js.Context,

    fn init(allocator: std.mem.Allocator, writer: *std.io.Writer) !RenderContext {
        return .{
            .writer = writer,
            .js = try js.Context.init(allocator),
        };
    }

    fn deinit(self: *RenderContext) void {
        self.js.deinit();
    }

    fn renderNodes(ctx: *RenderContext, nodes: []const Template.Node) anyerror!void {
        for (nodes) |node| {
            try renderNode(ctx, node);
        }
    }

    fn renderNode(ctx: *RenderContext, node: Template.Node) anyerror!void {
        switch (node) {
            .element => |elem| try renderElement(ctx, elem),
            .text => |text| try ctx.write(text),
            .interpolation => |interp| {
                try ctx.writeExpr(interp);
            },
            .conditional => |cond| {
                if (ctx.evalBool(cond.condition)) {
                    try renderElement(ctx, cond.element);
                } else if (cond.else_element) |else_elem| {
                    try renderElement(ctx, else_elem);
                }
            },
            .loop => |loop| {
                const val = ctx.js.vm.get(loop.array_name) orelse return error.UndefinedVar;
                const arr = try val.into([]const vm.Value);

                for (arr) |item| {
                    try ctx.js.vm.define(loop.item_name, item);
                    try renderElement(ctx, loop.element);
                }
            },
        }
    }

    fn renderElement(ctx: *RenderContext, elem: Template.Element) anyerror!void {
        try ctx.writer.print("<{s}", .{elem.tag});
        for (elem.attrs) |attr| {
            // TODO: escaping
            try ctx.writer.print(" {s}=\"{s}\"", .{ attr.name, attr.value });
        }
        try ctx.writer.writeAll(">");
        try renderNodes(ctx, elem.children);
        try ctx.writer.print("</{s}>", .{elem.tag});
    }

    pub fn setData(self: *RenderContext, data: anytype) !void {
        const T = @TypeOf(data);

        if (T == vm.Value and data.kind() == .object) {
            const props = try data.into([]const vm.Prop);
            for (props) |prop| {
                try self.js.vm.define(prop.key, prop.value);
            }
        } else {
            inline for (std.meta.fields(T)) |f| {
                const value = @field(data, f.name);
                try self.js.vm.define(f.name, value);
            }
        }
    }

    pub fn evalBool(self: *RenderContext, expr: []const u8) bool {
        const val = self.js.eval(expr) catch return false;
        return val.isTruthy();
    }

    pub fn write(self: *RenderContext, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
    }

    pub fn writeEscaped(self: *RenderContext, bytes: []const u8) !void {
        for (bytes) |c| {
            switch (c) {
                '&' => try self.writer.writeAll("&amp;"),
                '<' => try self.writer.writeAll("&lt;"),
                '>' => try self.writer.writeAll("&gt;"),
                '"' => try self.writer.writeAll("&quot;"),
                '\'' => try self.writer.writeAll("&#39;"),
                else => try self.writer.writeByte(c),
            }
        }
    }

    pub fn writeExpr(self: *RenderContext, expr: []const u8) !void {
        const val = try self.js.eval(expr);

        switch (val.kind()) {
            // These should be safe
            .undefined, .null, .bool, .number, .fun, .err, .array, .object => {
                try val.format(self.writer);
            },
            .shortstring, .string => {
                const str = try val.into([]const u8);
                try self.writeEscaped(str);
            },
        }
    }
};

fn expectRender(input: []const u8, data: anytype, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tpl = try Template.parse(arena.allocator(), input);
    const res = try tpl.render(arena.allocator(), data);

    try std.testing.expectEqualStrings(expected, res);
}

test "rendering" {
    try expectRender("", .{}, "");
    try expectRender("Hello", .{}, "Hello");
    try expectRender("Hello {{ name }}", .{ .name = "Alice" }, "Hello Alice");
    try expectRender("<a>Hello {{ name }}</a>", .{ .name = "Alice" }, "<a>Hello Alice</a>");

    try expectRender("<p>{{ user.name }}</p>", .{ .user = .{ .name = "Bob", .age = 25 } }, "<p>Bob</p>");
    try expectRender("<p>{{ user.age }}</p>", .{ .user = .{ .name = "Bob", .age = 25 } }, "<p>25</p>");
    try expectRender("<p>{{ price * quantity }}</p>", .{ .price = 10, .quantity = 3 }, "<p>30</p>");
    try expectRender("<p>{{ items[0] + items[2] }}</p>", .{ .items = [_]u32{ 10, 20, 30 } }, "<p>40</p>");

    try expectRender("<div class=\"p-4\">\n  <p>Hello {{name}}</p>\n  <span>You have {{ n }} new messages</span></div>", .{ .name = "Alice", .n = 10 }, "<div class=\"p-4\">" ++
        "<p>Hello Alice</p>" ++
        "<span>You have 10 new messages</span>" ++
        "</div>");

    try expectRender(
        "<p>{{ html }}</p>",
        .{ .html = "<script>alert('xss')</script>" },
        "<p>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;</p>",
    );

    try expectRender("<a v-if='show'>Hidden</a>", .{ .show = false }, "");
    try expectRender("<a v-if='show'>Visible</a>", .{ .show = true }, "<a>Visible</a>");

    try expectRender("<a v-if='count'>Hidden</a>", .{ .count = 0 }, "");
    try expectRender("<a v-if='count'>Visible</a>", .{ .count = 1 }, "<a>Visible</a>");

    try expectRender("<a v-if='str'>Hidden</a>", .{ .str = "" }, "");
    try expectRender("<a v-if='str'>Visible</a>", .{ .str = "x" }, "<a>Visible</a>");

    try expectRender("<a v-if='show'>true</a><a v-else>false</a>", .{ .show = false }, "<a>false</a>");
    try expectRender("<a v-if='show'>true</a><a v-else>false</a>", .{ .show = true }, "<a>true</a>");

    try expectRender("<a v-for='num in nums'>{{ num }}</a>", .{ .nums = [_]u32{} }, "");
    try expectRender("<a v-for='num in nums'>{{ num }}</a>", .{ .nums = [_]u32{1} }, "<a>1</a>");
    try expectRender("<a v-for='num in nums'>{{ num }}</a>", .{ .nums = [_]u32{ 1, 2 } }, "<a>1</a><a>2</a>");
}
