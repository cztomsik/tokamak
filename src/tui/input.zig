const std = @import("std");
const Context = @import("context.zig").Context;
const Key = @import("context.zig").Key;

pub const TextInput = struct {
    buf: []u8,
    len: usize = 0,
    cursor: usize = 0,
    options: Options,

    pub const Options = struct {
        multiline: bool = false,
        start: usize = 0, // where we start "clearing", 0-based
    };

    pub fn handleKey(self: *TextInput, key: Key) void {
        switch (key) {
            .char => |c| if (std.ascii.isPrint(c)) {
                if (self.len >= self.buf.len) return;
                std.mem.copyBackwards(u8, self.buf[self.cursor + 1 .. self.len + 1], self.buf[self.cursor..self.len]);
                self.buf[self.cursor] = c;
                self.cursor += 1;
                self.len += 1;
            },
            .enter => if (self.options.multiline) {
                if (self.len >= self.buf.len) return;
                std.mem.copyBackwards(u8, self.buf[self.cursor + 1 .. self.len + 1], self.buf[self.cursor..self.len]);
                self.buf[self.cursor] = '\n';
                self.cursor += 1;
                self.len += 1;
            },
            .backspace => if (self.cursor > 0) {
                std.mem.copyForwards(u8, self.buf[self.cursor - 1 .. self.len - 1], self.buf[self.cursor..self.len]);
                self.cursor -= 1;
                self.len -= 1;
            },
            .delete => if (self.cursor < self.len) {
                std.mem.copyForwards(u8, self.buf[self.cursor .. self.len - 1], self.buf[self.cursor + 1 .. self.len]);
                self.len -= 1;
            },
            .left => if (self.cursor > 0) {
                self.cursor -= 1;
            },
            .right => if (self.cursor < self.len) {
                self.cursor += 1;
            },
            .home => self.cursor = 0,
            .end => self.cursor = self.len,
            else => {},
        }
    }

    pub fn text(self: *const TextInput) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn readFrom(self: *TextInput, ctx: *Context) !?[]const u8 {
        while (true) {
            switch (try ctx.readKey()) {
                .enter => {
                    try ctx.out.writeAll("\r\n");
                    try ctx.out.flush();
                    break;
                },
                .escape, .ctrl_c, .ctrl_d => return null,
                .paste_start => {
                    while (true) {
                        const k = try ctx.readKey();
                        if (k == .paste_end) break;
                        self.handleKey(k);
                    }
                },
                else => |key| self.handleKey(key),
            }

            // Move to start column (CHA is 1-based)
            try ctx.out.print("\x1b[{}G", .{self.options.start + 1});
            try ctx.out.writeAll(self.buf[0..self.len]);
            try ctx.out.writeAll("\x1b[K"); // clear to end of line
            try ctx.out.print("\x1b[{}G", .{self.options.start + 1 + self.cursor});
            try ctx.out.flush();
        }

        return self.text();
    }
};
