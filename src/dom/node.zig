const std = @import("std");
const util = @import("../util.zig");
const Document = @import("document.zig").Document;
const Element = @import("element.zig").Element;
const Text = @import("text.zig").Text;

// https://github.com/cztomsik/graffiti/blob/master/src/dom/node.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Node.js
pub const Node = struct {
    kind: enum { element, text, document },
    document: *Document,
    parent_node: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    previous_sibling: ?*Node = null,
    next_sibling: ?*Node = null,

    comptime {
        // @compileLog(@sizeOf(Node));
        std.debug.assert(@sizeOf(Node) <= 56);
    }

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

    pub fn insertBefore(self: *Node, child: *Node, before: *Node) void {
        if (before.previous_sibling) |prev| {
            prev.next_sibling = child;
            child.previous_sibling = prev;
        } else {
            self.first_child = child;
        }

        before.previous_sibling = child;
        child.next_sibling = before;
        child.parent_node = self;
    }

    pub fn removeChild(self: *Node, child: *Node) void {
        if (child.previous_sibling) |prev| {
            prev.next_sibling = child.next_sibling;
        } else {
            self.first_child = child.next_sibling;
        }

        if (child.next_sibling) |next| {
            next.previous_sibling = child.previous_sibling;
        } else {
            self.last_child = child.previous_sibling;
        }

        child.previous_sibling = null;
        child.next_sibling = null;
        child.parent_node = null;
    }

    pub fn depth(self: *Node) usize {
        var n: usize = 0;
        var next = self.parent_node;
        while (next) |p| : (next = p.parent_node) n += 1;
        return n;
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
        const Cx = struct {
            writer: *std.io.Writer,
            indent: usize = 0,

            fn open(cx: *@This(), el: *Element) !void {
                try cx.writer.writeByte('\n');
                try cx.writer.splatByteAll(' ', cx.indent);
                try cx.writer.print("<{s}", .{el.localName()});

                var next = el.attributes;
                while (next) |att| : (next = att.next) {
                    // TODO: entities
                    try cx.writer.print(" {s}=\"{s}\"", .{ att.name.name(), att.value.str() });
                }

                try cx.writer.writeByte('>');

                cx.indent += 2;
            }

            fn close(cx: *@This(), el: *Element) !void {
                cx.indent -= 2;

                if (!el.local_name.isVoid()) {
                    if (el.node.first_child != null) {
                        try cx.writer.writeByte('\n');
                        try cx.writer.splatByteAll(' ', cx.indent);
                    }

                    try cx.writer.print("</{s}>", .{el.localName()});
                }
            }

            fn text(cx: *@This(), tn: *Text) !void {
                // TODO: entities

                var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, tn.data.str(), " \t\r\n"), "\r\n");
                while (it.next()) |line| {
                    try cx.writer.writeByte('\n');
                    try cx.writer.splatByteAll(' ', cx.indent);
                    try cx.writer.writeAll(line);
                }
            }
        };

        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();

        var w = std.fs.File.stderr().writer(&.{});
        var cx = Cx{ .writer = &w.interface };
        self.visit(&cx) catch {};
    }

    fn downcast(self: *Node, comptime T: type) *T {
        return @alignCast(@fieldParentPtr("node", self));
    }
};
