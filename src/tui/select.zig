const std = @import("std");
const Context = @import("context.zig").Context;
const Key = @import("context.zig").Key;

pub const Select = struct {
    items: []const []const u8,
    cursor: usize = 0,

    pub fn handleKey(self: *Select, key: Key) void {
        switch (key) {
            .up => if (self.cursor > 0) {
                self.cursor -= 1;
            },
            .down => if (self.cursor < self.items.len - 1) {
                self.cursor += 1;
            },
            else => {},
        }
    }

    /// Returns the index of the selected item, or null on escape/ctrl_c/ctrl_d.
    pub fn readFrom(self: *Select, ctx: *Context) !?usize {
        try self.render(ctx);

        while (true) {
            switch (try ctx.readKey()) {
                .enter => {
                    try self.erase(ctx);
                    return self.cursor;
                },
                .escape, .ctrl_c, .ctrl_d => {
                    try self.erase(ctx);
                    return null;
                },
                else => |k| self.handleKey(k),
            }
            try ctx.out.print("\x1b[{}A", .{self.items.len});
            try self.render(ctx);
        }
    }

    fn render(self: *Select, ctx: *Context) !void {
        for (self.items, 0..) |item, i| {
            if (i == self.cursor) {
                try ctx.out.print("\x1b[7m{s}\x1b[0m\r\n", .{item});
            } else {
                try ctx.out.print("{s}\r\n", .{item});
            }
        }
        try ctx.out.flush();
    }

    fn erase(self: *Select, ctx: *Context) !void {
        try ctx.out.print("\x1b[{}A", .{self.items.len});
        for (0..self.items.len) |_| {
            try ctx.out.writeAll("\x1b[2K\r\n");
        }
        try ctx.out.print("\x1b[{}A", .{self.items.len});
        try ctx.out.flush();
    }
};
