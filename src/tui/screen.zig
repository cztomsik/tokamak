const std = @import("std");
const ansi = @import("../ansi.zig");

// TODO: we should do some buffering anyway and then most of the drawing will be error-free
pub const Screen = struct {
    in: *std.io.Reader,
    out: *std.io.Writer,
    fin: std.fs.File.Reader,
    fout: std.fs.File.Writer,
    original_termios: std.posix.termios,

    pub fn init(self: *Screen, gpa: std.mem.Allocator) !void {
        const io_buf = try gpa.alloc(u8, 2 * 4096);
        errdefer gpa.free(io_buf);

        const stdin = std.fs.File.stdin();
        if (!stdin.isTty()) return error.NotATty;

        const original = try std.posix.tcgetattr(stdin.handle);
        errdefer std.posix.tcsetattr(stdin.handle, .FLUSH, original) catch {};

        var raw = original;
        raw.lflag = .{};
        raw.iflag = .{};
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

        self.fin = stdin.reader(io_buf[0 .. io_buf.len / 2]);
        self.fout = std.fs.File.stdout().writer(io_buf[io_buf.len / 2 ..]);
        self.in = &self.fin.interface;
        self.out = &self.fout.interface;
        self.original_termios = original;

        try self.out.writeAll("\x1b[?1049h\x1b[?2004h\x1b[?25l");
        try self.out.flush();
    }

    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        self.out.writeAll("\x1b[?25h\x1b[?2004l\x1b[?1049l") catch {};
        self.out.flush() catch {};
        std.posix.tcsetattr(self.fin.file.handle, .FLUSH, self.original_termios) catch {};
        gpa.free(self.in.buffer.ptr[0 .. 2 * self.in.buffer.len]);
    }

    pub fn clear(self: *Screen) !void {
        try self.out.writeAll(ansi.clear);
    }

    pub fn splat(self: *Screen, x: i32, y: i32, bytes: []const u8, n: i32, fg: ansi.Color, bg: ansi.Color) void {
        self.moveTo(x, y);
        self.out.print(ansi.csi ++ "{d};{d}m", .{ @intFromEnum(fg), @intFromEnum(bg) + 10 }) catch {};
        self.out.splatBytesAll(bytes, @intCast(n)) catch {};
    }

    pub fn termSize(self: *Screen) ![2]i32 {
        const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        var ws: Winsize = undefined;
        const TIOCGWINSZ: c_int = 0x40087468;
        if (std.c.ioctl(self.fout.file.handle, TIOCGWINSZ, &ws) != 0) return error.IoctlFailed;
        return .{ @intCast(ws.ws_col), @intCast(ws.ws_row) };
    }

    pub fn flush(self: *Screen) !void {
        self.out.writeAll(ansi.csi ++ "39;49m") catch {}; // Reset colors
        try self.out.flush();
    }

    fn moveTo(self: *Screen, x: i32, y: i32) void {
        self.out.print(ansi.csi ++ "{d};{d}H", .{ y + 1, x + 1 }) catch {};
    }
};
