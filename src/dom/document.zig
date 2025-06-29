const std = @import("std");
const sax = @import("../sax.zig");
const entities = @import("../entities.zig");
const util = @import("../util.zig");
const Node = @import("node.zig").Node;
const LocalName = @import("local_name.zig").LocalName;
const Element = @import("element.zig").Element;
const Text = @import("text.zig").Text;
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

    fn arenaSize(self: *Document) usize {
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
        return arena.queryCapacity();
    }

    // TODO: ParseOptions (so we can eagerly say that ie. we want to skip styles, scripts, ...)
    //       and we can also put keep_whitespace there
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

    // TODO: move to parser.zig?
    pub fn parseFromSax(allocator: std.mem.Allocator, parser: *sax.Parser) !*Document {
        const doc = try Document.init(allocator);
        errdefer doc.deinit();

        // This is our "stack"
        var top: *Node = &doc.node;

        var n_elem: usize = 0;
        var n_attr: usize = 0;
        var n_text: usize = 0;

        // TODO: ParseOptions
        parser.scanner.keep_whitespace = true;

        while (try parser.next()) |ev| {
            // std.debug.print("{s}", .{ev});

            switch (ev) {
                .open => |tag| {
                    const el = try doc.createElement(tag);
                    top.appendChild(&el.node);
                    n_elem += 1;

                    if (el.local_name.isRaw()) {
                        // Skip everything until the next </xxx>
                        while (try parser.next()) |ev2| {
                            // NOTE: We MUST NOT use `tag` anymore!
                            if (ev2 == .close and std.mem.eql(u8, ev2.close, el.localName())) break;
                        }
                    } else if (!el.local_name.isVoid()) {
                        // Push to the top
                        top = &el.node;
                    }
                },

                .attr => |att| {
                    if (top.element()) |el| {
                        try el.setAttribute(att.name, att.value);
                        n_attr += 1;
                    }
                },

                .text => |raw| {
                    if (top.element()) |el| {
                        const buf: []u8 = @constCast(raw); // TODO: it's not pretty but it should be safe
                        const tn = try doc.createTextNode(entities.decodeInplace(buf, entities.html4));
                        el.node.appendChild(&tn.node);
                        n_text += 1;
                    }
                },

                .close => |tag| {
                    if (tag.len == 0) continue; // /> is always ignored in HTML
                    const name = LocalName.parse(tag);

                    // Pop everything up to the closest element in the stack (if any)
                    var next = top.element();
                    while (next) |el| : (next = el.parentElement()) {
                        if (el.local_name == name) {
                            top = el.node.parent_node orelse unreachable;
                            break;
                        }
                    }
                },
            }
        }

        std.debug.print("mem used: {} unclosed: {} #el: {} #attr: {} #text: {}\n", .{
            std.fmt.fmtIntSizeDec(doc.arenaSize()),
            top.depth(),
            n_elem,
            n_attr,
            n_text,
        });

        // doc.node.dump();

        return doc;
    }

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
}
