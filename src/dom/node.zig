const std = @import("std");
const util = @import("../util.zig");
const Element = @import("element.zig").Element;
const Text = @import("text.zig").Text;

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
                std.debug.print("open {s}\n", .{el.local_name.name()});
            }

            fn close(_: @This(), el: *Element) !void {
                std.debug.print("close {s}\n", .{el.local_name.name()});
            }

            fn text(_: @This(), tn: *Text) !void {
                std.debug.print("{s}\n", .{tn.data[0..@min(32, tn.data.len)]});
            }
        }{});
    }

    fn downcast(self: *Node, comptime T: type) *T {
        std.debug.assert(self.kind == std.meta.fieldInfo(T, .node).defaultValue().?.kind);
        return @alignCast(@fieldParentPtr("node", self));
    }
};
