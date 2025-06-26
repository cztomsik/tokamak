// Here we go again...
// https://github.com/cztomsik/graffiti/tree/master/src/dom
// But this time, our scope is not that broad - this is only intended for
// scraping, querying, and simple transformations. Eventually, it could also be
// dumped into Markdown, PDF, or whatever, but the latter one or anything more
// complex is unlikely.

const std = @import("std");
const sax = @import("sax.zig");
const entities = @import("entities.zig");
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

    pub fn visit(self: *Node, visitor: anytype) !void {
        const Edge = union(enum) {
            open: *Node,
            close: *Node,
        };

        var next_edge: ?Edge = .{ .open = self };

        while (next_edge) |edge| {
            switch (edge) {
                .open => |curr| {
                    if (curr.element()) |el| try visitor.open(el);
                    if (curr.text()) |tn| try visitor.text(tn);

                    next_edge = if (curr.first_child) |child| .{ .open = child } else .{ .close = curr };
                },
                .close => |curr| {
                    if (curr.element()) |el| try visitor.close(el);
                    if (curr == self) break;

                    next_edge = if (curr.next_sibling) |sib| .{ .open = sib } else .{ .close = curr.parent_node orelse break };
                },
            }
        }
    }

    pub fn dump(self: *Node) void {
        try self.visit(struct {
            fn open(_: @This(), el: *Element) !void {
                std.debug.print("open {s}\n", .{@tagName(el.local_name)});
            }

            fn close(_: @This(), el: *Element) !void {
                std.debug.print("close {s}\n", .{@tagName(el.local_name)});
            }

            fn text(_: @This(), tn: *Text) !void {
                std.debug.print("{s}\n", .{tn.data[0..@min(32, tn.data.len)]});
            }
        }{});
    }

    fn downcast(self: *Node, comptime T: type) *T {
        std.debug.assert(self.kind == std.meta.fieldInfo(T, .node).defaultValue().?.kind);
        return @fieldParentPtr("node", self);
    }
};

// TODO: packed union, Symbol?
pub const LocalName = enum(u8) {
    a,
    abbr,
    address,
    area,
    article,
    aside,
    audio,
    b,
    base,
    bdi,
    bdo,
    blockquote,
    body,
    br,
    button,
    canvas,
    caption,
    cite,
    code,
    col,
    colgroup,
    data,
    datalist,
    dd,
    del,
    details,
    dfn,
    dialog,
    div,
    dl,
    dt,
    em,
    embed,
    fieldset,
    figcaption,
    figure,
    footer,
    form,
    frame,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    hgroup,
    hr,
    html,
    i,
    iframe,
    img,
    input,
    ins,
    isindex,
    kbd,
    keygen,
    label,
    legend,
    li,
    link,
    main,
    map,
    mark,
    math,
    menu,
    meta,
    meter,
    nav,
    noscript,
    object,
    ol,
    optgroup,
    option,
    output,
    p,
    param,
    picture,
    pre,
    progress,
    q,
    rp,
    rt,
    ruby,
    s,
    samp,
    script,
    search,
    section,
    select,
    slot,
    small,
    source,
    span,
    strong,
    style,
    sub,
    summary,
    sup,
    svg,
    table,
    tbody,
    td,
    template,
    textarea,
    tfoot,
    th,
    thead,
    time,
    title,
    tr,
    track,
    u,
    ul,
    @"var",
    video,
    wbr,
    unknown,

    pub fn parse(name: []const u8) LocalName {
        return std.meta.stringToEnum(LocalName, name) orelse .unknown;
    }

    pub fn isVoid(self: LocalName) bool {
        return switch (self) {
            .area, .base, .br, .col, .embed, .frame, .hr, .img, .input, .isindex, .keygen, .link, .meta, .param, .source, .track, .wbr => true,
            else => false,
        };
    }

    pub fn isRaw(self: LocalName) bool {
        return switch (self) {
            .script, .style => true,
            else => false,
        };
    }
};

// https://github.com/cztomsik/graffiti/blob/master/src/dom/element.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Element.js
pub const Element = struct {
    node: Node = .{ .kind = .element },
    local_name: LocalName,
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
        return @tagName(self.local_name);
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

    fn dupe(self: *Document, text: []const u8) ![]const u8 {
        return self.arena().dupe(u8, text);
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
