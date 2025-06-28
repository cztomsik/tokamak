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
    node: Node = .{ .kind = .document },
    nodes: std.heap.MemoryPool(NodeWrap),

    const NodeWrap = union {
        element: Element,
        text: Text,
    };

    comptime {
        // @compileLog(@sizeOf(NodeWrap));
        std.debug.assert(@sizeOf(NodeWrap) <= 128);
    }

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

                        // TODO: avoid double-cloning, and maybe we could join too? (later)
                        // TODO: and maybe the whole iterator api is nonsense too?
                        var chunks = entities.Decoder(entities.html4).init(raw);
                        while (chunks.next()) |chunk| {
                            const tn = try doc.createTextNode(chunk);
                            el.node.appendChild(&tn.node);
                            n_text += 1;
                        }
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
            std.fmt.fmtIntSizeDec(doc.nodes.arena.queryCapacity()),
            999, // TODO: count distance to the root
            n_elem,
            n_attr,
            n_text,
        });

        // doc.node.dump();

        return doc;
    }

    pub fn createElement(self: *Document, local_name: []const u8) !*Element {
        const wrap = try self.nodes.create();
        errdefer self.nodes.destroy(wrap);

        wrap.* = .{
            .element = .{
                .local_name = .parse(local_name),
                .attributes = .init(self.arena()),
            },
        };
        return &wrap.element;
    }

    pub fn createTextNode(self: *Document, data: []const u8) !*Text {
        // const trimmed = std.mem.trim(u8, data, " \t\r\n");
        // std.debug.print("len: {} trimmed: {}\n", .{ data.len, trimmed.len });

        const wrap = try self.nodes.create();
        errdefer self.nodes.destroy(wrap);

        wrap.* = .{
            .text = .{
                .data = try .init(self.arena(), data),
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
        return .init(self.gpa(), selector, self.documentElement(), null);
    }

    pub fn documentElement(self: *Document) ?*Element {
        return if (self.node.first_child) |node| node.element() else null;
    }

    // TODO: pub fn $() and $$()? (monad-like err-wrapping, fluent api, good-enough for simple modifications?)
    // https://github.com/cheeriojs/cheerio https://api.jquery.com/ https://zeptojs.com/

    fn arena(self: *Document) std.mem.Allocator {
        return self.nodes.arena.allocator();
    }

    fn gpa(self: *Document) std.mem.Allocator {
        return self.nodes.arena.child_allocator;
    }
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
