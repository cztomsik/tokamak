const std = @import("std");
const util = @import("../util.zig");
const Node = @import("node.zig").Node;
const Document = @import("document.zig").Document;

// https://github.com/cztomsik/graffiti/blob/master/src/dom/character_data.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/CharacterData.js
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Text.js
pub const Text = struct {
    node: Node,
    data: util.Smol128,

    comptime {
        // @compileLog(@sizeOf(Text));
        std.debug.assert(@sizeOf(Text) <= 80);
    }

    pub fn init(self: *Text, document: *Document, data: []const u8) !void {
        self.* = .{
            .node = .{ .document = document, .kind = .text },
            .data = try .init(document.arena, data),
        };
    }
};
