// Here we go again...
// https://github.com/cztomsik/graffiti/tree/master/src/dom
// But this time, our scope is not that broad - this is only intended for
// scraping, querying, and simple transformations. Eventually, it could also be
// dumped into Markdown, PDF, or whatever, but the latter one or anything more
// complex is unlikely.

const std = @import("std");
const sax = @import("sax.zig");
const Selector = @import("selector.zig").Selector;
const QuerySelectorIterator = @import("selector.zig").QuerySelectorIterator;

// https://github.com/cztomsik/graffiti/blob/master/src/dom/node.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Node.js
pub const Node = struct {
    kind: enum { element, text, document },
    parent_node: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    previous_sibling: ?*Node = null,
    next_sibling: ?*Node = null,

    pub fn element(self: *Node) ?*Element {
        return if (self.kind == .element) self.downcast(Element) else null;
    }

    pub fn text(self: *Node) ?*Text {
        return if (self.kind == .text) self.downcast(Text) else null;
    }

    pub fn appendChild(self: *Node, child: *Node) void {
        if (self.last_child) |last| {
            last.next_sibling = child;
            child.previous_sibling = last;
        } else {
            self.first_child = child;
        }

        self.last_child = child;
        child.parent_node = self;
    }

    fn downcast(self: *Node, comptime T: type) *T {
        std.debug.assert(self.kind == std.meta.fieldInfo(T, .node).defaultValue().?.kind);
        return @fieldParentPtr("node", self);
    }
};

// https://github.com/cztomsik/graffiti/blob/master/src/dom/element.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Element.js
pub const Element = struct {
    node: Node = .{ .kind = .element },
    local_name: []const u8,
    attributes: std.BufMap,

    pub fn parentElement(self: *Element) ?*Element {
        return if (self.node.parent_node) |node| node.element() else null;
    }

    pub fn firstElementChild(self: *Element) ?*Element {
        var next = self.node.first_child;
        while (next) |node| : (next = node.next_sibling) {
            return node.element() orelse continue;
        } else return null;
    }

    pub fn previousElementSibling(self: *Element) ?*Element {
        var next = self.node.previous_sibling;
        while (next) |node| : (next = node.previous_sibling) {
            return node.element() orelse continue;
        } else return null;
    }

    pub fn nextElementSibling(self: *Element) ?*Element {
        var next = self.node.next_sibling;
        while (next) |node| : (next = node.next_sibling) {
            return node.element() orelse continue;
        } else return null;
    }

    pub fn localName(self: *Element) []const u8 {
        return self.local_name;
    }

    pub fn id(self: *Element) []const u8 {
        return self.getAttribute("id") orelse "";
    }

    pub fn className(self: *Element) []const u8 {
        return self.getAttribute("class") orelse "";
    }

    pub fn getAttribute(self: *Element, name: []const u8) ?[]const u8 {
        return self.attributes.get(name);
    }

    pub fn setAttribute(self: *Element, name: []const u8, value: []const u8) !void {
        try self.attributes.put(name, value);
    }
};

// https://github.com/cztomsik/graffiti/blob/master/src/dom/character_data.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/CharacterData.js
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Text.js
pub const Text = struct {
    node: Node = .{ .kind = .text },
    data: []const u8,
};

// https://github.com/cztomsik/graffiti/blob/master/src/dom/document.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Document.js
pub const Document = struct {
    node: Node = .{ .kind = .document },
    nodes: std.heap.MemoryPool(NodeWrap),

    const NodeWrap = union {
        element: Element,
        text: Text,
    };

    pub fn init(allocator: std.mem.Allocator) !*Document {
        const self = try allocator.create(Document);
        errdefer allocator.destroy(self);

        self.* = .{
            .nodes = try .initPreheated(allocator, 256),
        };

        return self;
    }

    pub fn deinit(self: *Document) void {
        const allocator = self.gpa();
        self.nodes.deinit();
        allocator.destroy(self);
    }

    pub fn parseFromSlice(allocator: std.mem.Allocator, input: []const u8) !*Document {
        var parser = sax.Parser.initCompleteInput(input);
        return parseFromSax(allocator, &parser);
    }

    pub fn parseFromStream(allocator: std.mem.Allocator, reader: std.io.AnyReader) !*Document {
        const buf = try allocator.alloc(u8, 200 * 1024);
        defer allocator.free(buf);

        var parser = sax.Parser.initStreaming(buf, reader);
        return parseFromSax(allocator, &parser);
    }

    pub fn parseFromSax(allocator: std.mem.Allocator, parser: *sax.Parser) !*Document {
        const doc = try Document.init(allocator);
        errdefer doc.deinit();

        var stack: std.ArrayList(*Node) = try .initCapacity(allocator, 64);
        defer stack.deinit();

        try stack.append(&doc.node);
        parser.scanner.keep_whitespace = true;

        while (try parser.next()) |ev| {
            switch (ev) {
                .open => |tag| {
                    const el = try doc.createElement(tag);
                    if (stack.items.len > 0) stack.getLast().appendChild(&el.node);
                    try stack.append(&el.node);
                },

                .attr => |att| {
                    try stack.getLast().element().?.setAttribute(att.name, att.value);
                },

                .text => |raw| {
                    // TODO: decode entities (in chunks); avoid double-cloning; maybe we could join too (later)
                    const tn = try doc.createTextNode(raw);
                    if (stack.items.len > 0) stack.getLast().appendChild(&tn.node);
                },

                .close => {
                    _ = stack.pop();
                },
            }
        }

        std.debug.print(
            "mem used: {}\n",
            .{std.fmt.fmtIntSizeDec(doc.nodes.arena.queryCapacity())},
        );

        return doc;
    }

    pub fn createElement(self: *Document, local_name: []const u8) !*Element {
        const wrap = try self.nodes.create();
        errdefer self.nodes.destroy(wrap);

        wrap.* = .{
            .element = .{
                .local_name = try self.dupe(local_name),
                .attributes = .init(self.arena()),
            },
        };
        return &wrap.element;
    }

    pub fn createTextNode(self: *Document, data: []const u8) !*Text {
        const wrap = try self.nodes.create();
        errdefer self.nodes.destroy(wrap);

        wrap.* = .{
            .text = .{
                .data = try self.dupe(data),
            },
        };
        return &wrap.text;
    }

    pub fn querySelector(self: *Document, selector: []const u8) !?*Element {
        var qsa = try self.querySelectorAll(selector);
        defer qsa.deinit();

        return qsa.next();
    }

    pub fn querySelectorAll(self: *Document, selector: []const u8) !QuerySelectorIterator(*Element) {
        return .init(self.gpa(), selector, if (self.node.first_child) |node| node.element() else null);
    }

    fn arena(self: *Document) std.mem.Allocator {
        return self.nodes.arena.allocator();
    }

    fn gpa(self: *Document) std.mem.Allocator {
        return self.nodes.arena.child_allocator;
    }

    fn dupe(self: *Document, text: []const u8) ![]const u8 {
        return self.arena().dupe(u8, text);
    }
};

test {
    var doc = try Document.parseFromSlice(std.testing.allocator, "<html><body><div class='btn'>Hello<br></div></body></html>");
    defer doc.deinit();

    try std.testing.expect(doc.node.first_child != null);
    try std.testing.expect(doc.node.first_child.?.element() != null);
    try std.testing.expectEqualStrings(doc.node.first_child.?.element().?.localName(), "html");

    const el = try doc.querySelector("div.btn");
    try std.testing.expect(el != null);
}
