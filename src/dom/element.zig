const std = @import("std");
const util = @import("../util.zig");
const Node = @import("node.zig").Node;
const Document = @import("document.zig").Document;
const LocalName = @import("local_name.zig").LocalName;

pub const Attr = struct {
    next: ?*Attr = null,
    name: LocalName,
    value: util.Smol128,
};

// https://github.com/cztomsik/graffiti/blob/master/src/dom/element.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Element.js
pub const Element = struct {
    node: Node,
    local_name: LocalName,

    comptime {
        // @compileLog(@sizeOf(Element));
        std.debug.assert(@sizeOf(Element) <= 80);
    }

    pub fn init(self: *Element, document: *Document, local_name: []const u8) !void {
        self.* = .{
            .node = .{ .document = document, .kind = .element },
            .local_name = .parse(local_name),
        };
    }

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
        return self.local_name.name();
    }

    pub fn id(self: *Element) []const u8 {
        return self.getAttribute("id") orelse "";
    }

    pub fn className(self: *Element) []const u8 {
        return self.getAttribute("class") orelse "";
    }

    pub fn getAttribute(self: *Element, name: []const u8) ?[]const u8 {
        return self.node.document.attrs.getAttribute(self, name);
    }

    pub fn setAttribute(self: *Element, name: []const u8, value: []const u8) !void {
        return self.node.document.attrs.setAttribute(self, name, value);
    }
};
