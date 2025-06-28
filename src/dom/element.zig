const std = @import("std");
const util = @import("../util.zig");
const Node = @import("node.zig").Node;
const LocalName = @import("local_name.zig").LocalName;

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
        return self.local_name.name();
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
