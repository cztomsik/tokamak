const std = @import("std");
const sax = @import("../sax.zig");
const entities = @import("../entities.zig");
const Document = @import("document.zig").Document;
const Node = @import("node.zig").Node;
const LocalName = @import("local_name.zig").LocalName;
const Element = @import("element.zig").Element;
const Text = @import("text.zig").Text;

pub const HtmlParser = struct {
    sax: sax.Parser,

    pub fn initCompleteInput(input: []const u8) HtmlParser {
        return .{
            .sax = .initCompleteInput(input),
        };
    }

    pub fn initStreaming(buf: []u8, reader: std.io.AnyReader) HtmlParser {
        return .{
            .sax = .initStreaming(buf, reader),
        };
    }

    pub fn parseDocument(self: *HtmlParser, allocator: std.mem.Allocator) !*Document {
        const doc = try Document.init(allocator);
        errdefer doc.deinit();

        try self.parseInto(&doc.node);
        // doc.node.dump();
        return doc;
    }

    pub fn parseInto(self: *HtmlParser, root: *Node) !void {
        const doc = root.document;

        // This is our "stack", we are still pushing/popping but because our
        // tree is essentially linked-list, we only need one variable.
        // It can only contain elements and the root node.
        var top: *Node = root;

        var n_elem: usize = 0;
        var n_attr: usize = 0;
        var n_text: usize = 0;

        // TODO: ParseOptions
        self.sax.scanner.keep_whitespace = true;

        while (try self.sax.next()) |ev| {
            // std.debug.print("{s}", .{ev});

            switch (ev) {
                .open => |tag| {
                    const el = try doc.createElement(tag);
                    top.appendChild(&el.node);
                    n_elem += 1;

                    if (el.local_name.isRaw()) {
                        // Skip everything until the next </xxx>
                        while (try self.sax.next()) |ev2| {
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
                        // TODO: avoid @constCast(), avoid checking is_eof!
                        const decoded = if (!self.sax.is_eof)
                            entities.decodeInplace(@constCast(raw), entities.html4)
                        else
                            try entities.decode(doc.arena, raw, entities.html4);

                        const tn = try doc.createTextNode(decoded);
                        el.node.appendChild(&tn.node);
                        n_text += 1;
                    }
                },

                .close => |tag| {
                    if (tag.len == 0) continue; // /> is always ignored in HTML
                    const name = LocalName.parse(tag);

                    // Pop everything up to the closest element in the stack (if any)
                    // NOTE: whatever is in the stack, it is guranteed to be attached already (parent_node != null)
                    //       furthermore, we only push elements, so we can rely on that too
                    var next = top;
                    while (next != root) : (next = next.parent_node.?) {
                        const el = next.element().?;
                        if (el.local_name == name) {
                            top = el.node.parent_node.?;
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
    }
};
