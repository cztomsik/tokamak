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
        raw.oflag.OPOST = false;
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

        return ctx;
    }

    pub fn deinit(self: *Context) void {
        const allocator = self.allocator;
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

    pub fn readLine(self: *Context, buf: []u8) !?[]const u8 {
        var len: usize = 0;

        while (true) {
            switch (try self.readKey()) {
                .enter => break,
                .escape => return null,
                .backspace => {
                    if (len > 0) {
                        len -= 1;
                        try self.out.writeAll("\x08 \x08");
                    }
                },
                .char => |c| {
                    if (len < buf.len - 1 and std.ascii.isPrint(c)) {
                        buf[len] = c;
                        len += 1;
                        try self.out.print("{c}", .{c});
                        try self.out.flush();
                    }
                },
                else => {},
            }
        }

        return buf[0..len];
    }

    pub fn readKey(self: *Context) !Key {
        const ch = try self.readByte();

        return switch (ch) {
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
                const fkey: Key = switch (try self.readByte()) {
                    '0' => .f9,
                    '1' => .f10,
                    '3' => .f11,
                    '4' => .f12,
                    else => return .escape,
                };

                self.in.toss(1); // ~
                return fkey;
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
