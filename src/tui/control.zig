const std = @import("std");
const Context = @import("context.zig").Context;
const Frame = @import("frame.zig").Frame;
const Key = @import("input.zig").Key;

pub const Control = struct {
    focused: bool,
    pressed: bool,
    last_key: ?Key,
    cursor: *usize,

    pub fn init(ctx: *Context) Control {
        const id: usize = @intCast(ctx.n_controls);
        const focused = ctx.focus == ctx.n_controls;
        ctx.n_controls += 1;

        const pressed = focused and if (ctx.last_key) |k| switch (k) {
            .enter => true,
            .char => |c| c == ' ',
            else => false,
        } else false;

        return .{
            .focused = focused,
            .pressed = pressed,
            .last_key = if (focused) ctx.last_key else null,
            .cursor = &ctx.cursors[@min(id, ctx.cursors.len - 1)],
        };
    }

    pub fn toggle(self: Control, value: *bool) void {
        if (self.pressed) value.* = !value.*;
    }

    pub fn hdir(self: Control) i2 {
        return if (self.last_key) |k| switch (k) {
            .left => -1,
            .right => 1,
            else => 0,
        } else 0;
    }

    pub fn navigate(self: Control, selected: *usize, count: usize) void {
        if (count == 0) return;
        const dir: i2 = if (self.last_key) |k| switch (k) {
            .up => -1,
            .down => 1,
            else => 0,
        } else 0;
        if (dir == 0) return;
        selected.* = @intCast(std.math.clamp(
            @as(isize, @intCast(selected.*)) + dir,
            0,
            @as(isize, @intCast(count)) - 1,
        ));
    }

    pub fn editNumber(self: Control, value: *i32) void {
        if (self.last_key) |k| switch (k) {
            .backspace => value.* = @divTrunc(value.*, 10),
            .char => |ch| switch (ch) {
                '0'...'9' => {
                    const digit: i32 = ch - '0';
                    value.* = if (value.* >= 0)
                        value.* *| 10 +| digit
                    else
                        value.* *| 10 -| digit;
                },
                '-' => value.* = 0 -| value.*,
                else => {},
            },
            else => {},
        };
    }

    pub fn editText(self: Control, buf: []u8, len: *usize) void {
        const cursor = self.cursor;
        cursor.* = @min(cursor.*, len.*);

        if (self.last_key) |k| switch (k) {
            .char => |ch| if (std.ascii.isPrint(ch) and len.* < buf.len) {
                std.mem.copyBackwards(u8, buf[cursor.* + 1 .. len.* + 1], buf[cursor.*..len.*]);
                buf[cursor.*] = ch;
                cursor.* += 1;
                len.* += 1;
            },
            .backspace => if (cursor.* > 0) {
                std.mem.copyForwards(u8, buf[cursor.* - 1 .. len.* - 1], buf[cursor.*..len.*]);
                cursor.* -= 1;
                len.* -= 1;
            },
            .delete => if (cursor.* < len.*) {
                std.mem.copyForwards(u8, buf[cursor.* .. len.* - 1], buf[cursor.* + 1 .. len.*]);
                len.* -= 1;
            },
            .left => if (cursor.* > 0) {
                cursor.* -= 1;
            },
            .right => if (cursor.* < len.*) {
                cursor.* += 1;
            },
            .home => cursor.* = 0,
            .end => cursor.* = len.*,
            else => {},
        };
    }
};
