const std = @import("std");
const sax = @import("../sax.zig");
const util = @import("../util.zig");
const Node = @import("node.zig").Node;
const Element = @import("element.zig").Element;
const Text = @import("text.zig").Text;
const HtmlParser = @import("parser.zig").HtmlParser;
const Selector = @import("../selector.zig").Selector;
const QuerySelectorIterator = @import("../selector.zig").QuerySelectorIterator;

// https://github.com/cztomsik/graffiti/blob/master/src/dom/document.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Document.js
pub const Document = struct {
    node: Node,
    arena: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Document {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const self = try arena.allocator().create(Document);
        self.* = .{
            .node = .{ .document = self, .kind = .document },
            .arena = arena.allocator(),
        };
        return self;
    }

    pub fn deinit(self: *Document) void {
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
        const allocator = arena.child_allocator;

        arena.deinit();
        allocator.destroy(arena);
    }

    pub fn arenaSize(self: *Document) usize {
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
        return arena.queryCapacity();
    }

    // TODO: ParseOptions (so we can eagerly say that ie. we want to skip styles, scripts, ...)
    //       and we can also put keep_whitespace there
    pub fn parseFromSlice(allocator: std.mem.Allocator, input: []const u8) !*Document {
        var parser = HtmlParser.initCompleteInput(input);
        return parser.parseDocument(allocator);
    }

    pub fn parseFromStream(allocator: std.mem.Allocator, reader: *std.io.Reader) !*Document {
        var parser = HtmlParser.initStreaming(reader);
        return parser.parseDocument(allocator);
    }

    // TODO: move to parser.zig?

    pub fn createElement(self: *Document, local_name: []const u8) !*Element {
        const element = try self.arena.create(Element);
        try element.init(self, local_name);
        return element;
    }

    pub fn createTextNode(self: *Document, data: []const u8) !*Text {
        // TODO: not sure if want to do anything about whitespace, it doesn't look that bad
        // if (data.len > 12) {
        //     const trimmed = std.mem.trim(u8, data, " \t\r\n");
        //     std.debug.print("len: {} trimmed: {}\n", .{ data.len, trimmed.len });
        // }

        const text = try self.arena.create(Text);
        try text.init(self, data);
        return text;
    }

    pub fn querySelector(self: *Document, selector: []const u8) !?*Element {
        var qsa = try self.querySelectorAll(selector);
        defer qsa.deinit();

        return qsa.next();
    }

    pub fn querySelectorAll(self: *Document, selector: []const u8) !QuerySelectorIterator(*Element) {
        // TODO: maybe we should accept allocator and the querySelector() should either do so too or it could use fba on the stack
        //       or maybe both could and we could also add xxxAlloc() variants for unbounded selectors
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
        const gpa = arena.child_allocator;
        return .init(gpa, selector, self.documentElement(), null);
    }

    pub fn documentElement(self: *Document) ?*Element {
        return if (self.node.first_child) |node| node.element() else null;
    }

    // TODO: pub fn $() and $$()? (monad-like err-wrapping, fluent api, good-enough for simple modifications?)
    // https://github.com/cheeriojs/cheerio https://api.jquery.com/ https://zeptojs.com/
};

test {
    var doc = try Document.parseFromSlice(std.testing.allocator, "<html lang='en'><body><div><button class='btn'>Hello <i>World</i></button><br></div></body></html>");
    defer doc.deinit();

    const html = doc.documentElement().?;
    try std.testing.expectEqualStrings("html", html.localName());
    try std.testing.expectEqualStrings("en", html.getAttribute("lang").?);

    const btn = try doc.querySelector("div .btn");
    try std.testing.expect(btn != null);

    const span = try doc.createElement("span");
    btn.?.node.parent_node.?.insertBefore(&span.node, &btn.?.node);

    try std.testing.expectEqual(btn, (try doc.querySelector("span + .btn")).?);
}

// test "real-world html" {
//     // curl https://www.w3.org/TR/css-grid-1/ > bench.html
//     var doc = try Document.parseFromSlice(std.testing.allocator, @embedFile("bench.html"));
//     defer doc.deinit();
// }
