const std = @import("std");
const Context = @import("context.zig").Context;
const Frame = @import("frame.zig").Frame;
const input = @import("input.zig");
const Key = input.Key;

const PasteMode = enum { single_line, preserve_newlines };

pub fn Control(comptime T: type) type {
    return struct {
        ctx: *Context,
        value: *T,
        focused: bool,
        pending_key: ?Key,

        const Ctrl = @This();

        pub fn init(ctx: *Context, value: *T) Ctrl {
            const id = ctx.n_controls;
            const focused = ctx.focus == id;
            ctx.n_controls += 1;

            return .{
                .ctx = ctx,
                .value = value,
                .focused = focused,
                .pending_key = if (focused) ctx.pending_key else null,
            };
        }

        pub fn set(self: Ctrl, new_value: T) void {
            self.value.* = new_value;
            self.ctx.next_tick = .clear;
        }

        pub fn toggle(self: Ctrl) void {
            self.set(!self.value.*);
        }

        pub fn pressed(self: Ctrl) bool {
            return if (self.pending_key) |k| switch (k) {
                .enter => true,
                .char => |c| c == ' ',
                else => false,
            } else false;
        }

        pub fn navigate(self: Ctrl, keys: [2]Key, len: usize) void {
            if (len > 0) {
                if (self.pending_key) |k| {
                    if (std.meta.eql(k, keys[0])) self.set((self.value.* + len - 1) % len);
                    if (std.meta.eql(k, keys[1])) self.set((self.value.* + 1) % len);
                }
            }
        }

        // TODO: everything below is tech-debt

        pub fn editText(self: Ctrl, buf: []u8, len: *usize, cur: *usize) void {
            cur.* = @min(cur.*, len.*);

            switch (self.pending_key orelse return) {
                .char => |ch| {
                    if (!insertCodepoint(buf, len, cur, ch)) return;
                },
                .paste_start => if (!self.pasteText(buf, len, cur, .single_line)) return,
                .backspace => if (cur.* > 0) {
                    const n = prevCodepointLen(buf[0..cur.*]);
                    std.mem.copyForwards(u8, buf[cur.* - n .. len.* - n], buf[cur.*..len.*]);
                    cur.* -= n;
                    len.* -= n;
                },
                .delete => if (cur.* < len.*) {
                    const n = std.unicode.utf8ByteSequenceLength(buf[cur.*]) catch 1;
                    const end = @min(cur.* + n, len.*);
                    std.mem.copyForwards(u8, buf[cur.* .. len.* - (end - cur.*)], buf[end..len.*]);
                    len.* -= end - cur.*;
                },
                .left => if (cur.* > 0) {
                    cur.* -= prevCodepointLen(buf[0..cur.*]);
                },
                .right => if (cur.* < len.*) {
                    cur.* += std.unicode.utf8ByteSequenceLength(buf[cur.*]) catch 1;
                    cur.* = @min(cur.*, len.*);
                },
                .home, .up => cur.* = 0,
                .end, .down => cur.* = len.*,
                else => return,
            }

            self.ctx.next_tick = .clear;
        }

        pub fn editTextArea(self: Ctrl, buf: []u8, len: *usize, cur: *usize) void {
            cur.* = @min(cur.*, len.*);

            switch (self.pending_key orelse return) {
                .enter => if (!insertCodepoint(buf, len, cur, '\n')) return,
                .paste_start => if (!self.pasteText(buf, len, cur, .preserve_newlines)) return,
                else => {
                    self.editText(buf, len, cur);
                    return;
                },
            }

            self.ctx.next_tick = .clear;
        }

        fn pasteText(self: Ctrl, buf: []u8, len: *usize, cur: *usize, mode: PasteMode) bool {
            var inserted = false;

            while (true) {
                const maybe_key = input.pollKey(&self.ctx.screen.fin, 1000) catch null;

                switch (maybe_key orelse break) {
                    .paste_end => break,
                    .char => |ch| if (ch >= 0x20 and ch != 0x7F) {
                        inserted = insertCodepoint(buf, len, cur, ch) or inserted;
                    },
                    .enter => {
                        const ch: u21 = if (mode == .preserve_newlines) '\n' else ' ';
                        inserted = insertCodepoint(buf, len, cur, ch) or inserted;
                    },
                    .tab => {
                        inserted = insertCodepoint(buf, len, cur, ' ') or inserted;
                    },
                    else => {},
                }
            }

            return inserted;
        }

        fn insertCodepoint(buf: []u8, len: *usize, cur: *usize, ch: u21) bool {
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(ch, &enc) catch return false;
            if (len.* + n > buf.len) return false;
            std.mem.copyBackwards(u8, buf[cur.* + n .. len.* + n], buf[cur.*..len.*]);
            @memcpy(buf[cur.* .. cur.* + n], enc[0..n]);
            cur.* += n;
            len.* += n;
            return true;
        }

        /// Return the byte length of the codepoint just before `pos` in `text`.
        fn prevCodepointLen(text: []const u8) usize {
            var i = text.len;
            while (i > 0) {
                i -= 1;
                // Continuation bytes have the pattern 10xxxxxx
                if (text[i] & 0xC0 != 0x80) break;
            }
            return text.len - i;
        }

        pub fn editNumber(self: Ctrl) void {
            switch (self.pending_key orelse return) {
                .backspace => self.value.* = @divTrunc(self.value.*, 10),
                .char => |ch| switch (ch) {
                    '0'...'9' => {
                        const digit: i32 = ch - '0';
                        self.value.* = if (self.value.* >= 0)
                            self.value.* *| 10 +| digit
                        else
                            self.value.* *| 10 -| digit;
                    },
                    '-' => self.value.* = 0 -| self.value.*,
                    else => {},
                },
                else => {},
            }
        }

        pub fn stepNumber(self: Ctrl, min: T, max: T, step: T) void {
            if (self.pending_key) |k| {
                self.value.* = std.math.clamp(if (comptime @typeInfo(@TypeOf(step)) == .float)
                    switch (k) {
                        .left => self.value.* - step,
                        .right => self.value.* + step,
                        else => return,
                    }
                else switch (k) {
                    .left => self.value.* -| step,
                    .right => self.value.* +| step,
                    else => return,
                }, min, max);
            }
        }
    };
}
