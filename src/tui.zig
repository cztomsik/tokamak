const std = @import("std");
const ansi = @import("ansi.zig");

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    tab,
    enter,
    backspace,
    delete,
    escape,
    ctrl_c,
    ctrl_d,
    paste_start,
    paste_end,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const TextEdit = struct {
    buf: []u8,
    len: usize = 0,
    cursor: usize = 0,
    options: Options,

    pub const Options = struct {
        multiline: bool = false,
    };

    pub fn handleKey(self: *TextEdit, key: Key) void {
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

    pub fn text(self: *const TextEdit) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    in: *std.io.Reader,
    out: *std.io.Writer,
    in_reader: std.fs.File.Reader,
    out_writer: std.fs.File.Writer,
    original_termios: std.posix.termios,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);

        const out_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(out_buf);

        const in_buf = try allocator.alloc(u8, 1024);
        errdefer allocator.free(in_buf);

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
            .allocator = allocator,
            .in = &ctx.in_reader.interface,
            .out = &ctx.out_writer.interface,
            .in_reader = stdin.reader(in_buf),
            .out_writer = std.fs.File.stdout().writer(out_buf),
            .original_termios = original,
        };

        try ctx.out.writeAll("\x1b[?2004h");
        try ctx.out.flush();

        return ctx;
    }

    pub fn deinit(self: *Context) void {
        const allocator = self.allocator;
        self.out.writeAll("\x1b[?2004l") catch {};
        self.out.flush() catch {};
        _ = std.posix.tcsetattr(self.in_reader.file.handle, .FLUSH, self.original_termios) catch {};
        allocator.free(self.in.buffer);
        allocator.free(self.out.buffer);
        allocator.destroy(self);
    }

    pub fn clear(self: *Context) !void {
        try self.out.writeAll(ansi.clear);
    }

    pub fn flush(self: *Context) !void {
        try self.out.flush();
    }

    pub fn readLine(self: *Context, buf: []u8, options: TextEdit.Options) !?[]const u8 {
        var editor = TextEdit{ .buf = buf, .options = options };

        while (true) {
            switch (try self.readKey()) {
                .enter => {
                    try self.out.writeAll("\r\n");
                    try self.out.flush();
                    break;
                },
                .escape, .ctrl_c, .ctrl_d => return null,
                .paste_start => {
                    while (true) {
                        const k = try self.readKey();
                        if (k == .paste_end) break;
                        editor.handleKey(k);
                    }
                },
                else => |key| editor.handleKey(key),
            }

            try self.out.writeAll("\r\x1b[K");
            try self.out.writeAll(editor.text());
            if (editor.cursor < editor.len) {
                try self.out.print("\x1b[{}D", .{editor.len - editor.cursor});
            }
            try self.out.flush();
        }

        return editor.text();
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
