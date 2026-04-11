const std = @import("std");
const ansi = @import("../ansi.zig");

const TextInput = @import("input.zig").TextInput;
const Select = @import("select.zig").Select;

pub const Key = union(enum) {
    // zig fmt: off
    char: u8,
    up, down, left, right,
    home, end, page_up, page_down,
    tab, enter, backspace, delete, escape,
    ctrl_c, ctrl_d,
    paste_start, paste_end,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    in: *std.io.Reader,
    out: *std.io.Writer,
    fin: std.fs.File.Reader,
    fout: std.fs.File.Writer,
    original_termios: std.posix.termios,

    pub fn init(gpa: std.mem.Allocator) !*Context {
        const ctx = try gpa.create(Context);
        errdefer gpa.destroy(ctx);

        const out_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(out_buf);

        const in_buf = try gpa.alloc(u8, 1024);
        errdefer gpa.free(in_buf);

        const stdin = std.fs.File.stdin();

        if (!stdin.isTty()) {
            return error.NotATty;
        }

        // TODO: initTermios() + errdefer
        const original = try std.posix.tcgetattr(stdin.handle);

        var raw = original;
        raw.lflag = .{};
        raw.iflag = .{};
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

        ctx.* = Context{
            .gpa = gpa,
            .in = &ctx.fin.interface,
            .out = &ctx.fout.interface,
            .fin = stdin.reader(in_buf),
            .fout = std.fs.File.stdout().writer(out_buf),
            .original_termios = original,
        };

        try ctx.out.writeAll("\x1b[?2004h");
        try ctx.out.flush();

        return ctx;
    }

    pub fn deinit(self: *Context) void {
        const gpa = self.gpa;
        self.out.writeAll("\x1b[?2004l") catch {};
        self.out.flush() catch {};
        _ = std.posix.tcsetattr(self.fin.file.handle, .FLUSH, self.original_termios) catch {};
        gpa.free(self.in.buffer);
        gpa.free(self.out.buffer);
        gpa.destroy(self);
    }

    pub fn clear(self: *Context) !void {
        try self.out.writeAll(ansi.clear);
    }

    pub fn flush(self: *Context) !void {
        try self.out.flush();
    }

    pub fn readLine(self: *Context, buf: []u8, options: TextInput.Options) !?[]const u8 {
        var editor = TextInput{ .buf = buf, .options = options };
        return editor.readFrom(self);
    }

    pub fn select(self: *Context, items: []const []const u8) !?usize {
        var s = Select{ .items = items };
        return s.readFrom(self);
    }

    pub fn readKey(self: *Context) !Key {
        const ch = try self.readByte();

        return switch (ch) {
            0x03 => .ctrl_c,
            0x04 => .ctrl_d,
            ansi.esc[0] => try self.readCSI(),
            '\t' => .tab,
            '\r', '\n' => .enter,
            0x7F, 0x08 => .backspace,
            else => .{ .char = ch },
        };
    }

    fn readByte(self: *Context) !u8 {
        return (try self.in.take(1))[0];
    }

    fn readCSI(self: *Context) !Key {
        const ch = try self.readByte();
        if (ch != '[') return .escape; // Not a CSI

        return switch (try self.readByte()) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '1' => {
                const fkey: Key = switch (try self.readByte()) {
                    '~' => .home,
                    '1' => .f1,
                    '2' => .f2,
                    '3' => .f3,
                    '4' => .f4,
                    '5' => .f5,
                    '7' => .f6,
                    '8' => .f7,
                    '9' => .f8,
                    else => return .escape,
                };

                self.in.toss(1); // ~
                return fkey;
            },
            '2' => {
                const b = try self.readByte();
                switch (b) {
                    '0' => {
                        const b2 = try self.readByte();
                        if (b2 == '~') return .f9; // \x1b[20~
                        // \x1b[200~ or \x1b[201~
                        self.in.toss(1); // ~
                        return switch (b2) {
                            '0' => .paste_start,
                            '1' => .paste_end,
                            else => .escape,
                        };
                    },
                    '1' => {
                        self.in.toss(1);
                        return .f10;
                    },
                    '3' => {
                        self.in.toss(1);
                        return .f11;
                    },
                    '4' => {
                        self.in.toss(1);
                        return .f12;
                    },
                    else => return .escape,
                }
            },
            '3' => {
                self.in.toss(1); // ~
                return .delete;
            },
            '4' => {
                self.in.toss(1);
                return .end;
            },
            '5' => {
                self.in.toss(1);
                return .page_up;
            },
            '6' => {
                self.in.toss(1);
                return .page_down;
            },
            else => .escape,
        };
    }

    pub fn print(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
    }

    pub fn println(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt ++ "\r\n", args);
    }
};
