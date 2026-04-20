const std = @import("std");
const Context = @import("context.zig").Context;
const Frame = @import("frame.zig").Frame;
const Key = @import("input.zig").Key;

pub const Control = struct {
    id: u32,
    ctx: *Context,
    cursor: *usize,

    pub fn init(ctx: *Context) Control {
        const id = ctx.n_controls;
        ctx.n_controls += 1;

        return .{
            .id = id,
            .ctx = ctx,
            .cursor = ctx.getState(id, usize, std.math.maxInt(usize)),
        };
    }

    pub fn pendingKey(self: Control) ?Key {
        return if (self.focused()) self.ctx.last_key else null;
    }

    pub fn focused(self: Control) bool {
        return self.ctx.focus == self.id;
    }

    pub fn pressed(self: Control) bool {
        return if (self.pendingKey()) |k| switch (k) {
            .enter => true,
            .char => |c| c == ' ',
            else => false,
        } else false;
    }

    pub fn toggle(self: Control, value: *bool) void {
        if (self.pressed()) value.* = !value.*;
    }

    pub fn navigate(self: Control, keys: [2]Key, selected: *usize, len: usize) void {
        if (len > 0) {
            if (self.pendingKey()) |k| {
                if (std.meta.eql(k, keys[0])) selected.* = (selected.* + len - 1) % len;
                if (std.meta.eql(k, keys[1])) selected.* = (selected.* + 1) % len;
            }
        }
    }

    pub fn editText(self: Control, buf: []u8, len: *usize) void {
        const cur = self.cursor;
        cur.* = @min(cur.*, len.*);

        switch (self.pendingKey() orelse return) {
            .char => |ch| if (std.ascii.isPrint(ch) and len.* < buf.len) {
                std.mem.copyBackwards(u8, buf[cur.* + 1 .. len.* + 1], buf[cur.*..len.*]);
                buf[cur.*] = ch;
                cur.* += 1;
                len.* += 1;
            },
            .backspace => if (cur.* > 0) {
                std.mem.copyForwards(u8, buf[cur.* - 1 .. len.* - 1], buf[cur.*..len.*]);
                cur.* -= 1;
                len.* -= 1;
            },
            .delete => if (cur.* < len.*) {
                std.mem.copyForwards(u8, buf[cur.* .. len.* - 1], buf[cur.* + 1 .. len.*]);
                len.* -= 1;
            },
            .left => if (cur.* > 0) {
                cur.* -= 1;
            },
            .right => if (cur.* < len.*) {
                cur.* += 1;
            },
            .home => cur.* = 0,
            .end => cur.* = len.*,
            else => {},
        }
    }

    pub fn editNumber(self: Control, value: *i32) void {
        switch (self.pendingKey() orelse return) {
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
        }
    }

    pub fn stepNumber(self: Control, value: anytype, min: @TypeOf(value.*), max: @TypeOf(value.*), step: @TypeOf(value.*)) void {
        if (self.pendingKey()) |k| {
            value.* = std.math.clamp(if (comptime @typeInfo(@TypeOf(step)) == .float)
                switch (k) {
                    .left => value.* - step,
                    .right => value.* + step,
                    else => return,
                }
            else switch (k) {
                .left => value.* -| step,
                .right => value.* +| step,
                else => return,
            }, min, max);
        }
    }
};
