const std = @import("std");
const util = @import("../util.zig");
const Node = @import("node.zig").Node;

// https://github.com/cztomsik/graffiti/blob/master/src/dom/character_data.zig
// https://github.com/cztomsik/graffiti/blob/master/lib/core/CharacterData.js
// https://github.com/cztomsik/graffiti/blob/master/lib/core/Text.js
pub const Text = struct {
    node: Node = .{ .kind = .text },
    data: util.Smol128,
};
