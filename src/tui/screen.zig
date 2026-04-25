const std = @import("std");
const ansi = @import("../ansi.zig");
const Color = @import("color.zig").Color;

pub const Feature = enum(u32) {
    /// Use a separate screen buffer so the app doesn't overwrite the shell
    alternate_screen = 1049,
    /// Allow pasting text safely without it being interpreted as keypresses
    bracketed_paste = 2004,
    /// Show the terminal cursor
    show_cursor = 25,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .white,
    bg: Color = .black,
    z: i32 = 0,
};

pub const Screen = struct {
    in: *std.io.Reader,
    out: *std.io.Writer,
    fin: std.fs.File.Reader,
    fout: std.fs.File.Writer,
    original_termios: std.posix.termios,
    cells: []Cell,
    width: i32,
    height: i32,
    truecolor: bool = false,

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
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

        self.truecolor = if (std.posix.getenv("COLORTERM")) |ct|
            std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")
        else
            false;

        self.fin = stdin.reader(io_buf[0 .. io_buf.len / 2]);
        self.fout = std.fs.File.stdout().writer(io_buf[io_buf.len / 2 ..]);
        self.in = &self.fin.interface;
        self.out = &self.fout.interface;
        self.original_termios = original;

        // Query initial terminal size and allocate cell buffer
        const size = try self.querySizeIoctl();
        self.width = size[0];
        self.height = size[1];
        const total: usize = @intCast(self.width * self.height);
        self.cells = try gpa.alloc(Cell, total);
        @memset(self.cells, Cell{});

        // Enable default features
        try self.set(.alternate_screen, true);
        try self.set(.bracketed_paste, true);
        try self.set(.show_cursor, false);
    }

    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        // Disable features in reverse order
        self.set(.show_cursor, true) catch {};
        self.set(.bracketed_paste, false) catch {};
        self.set(.alternate_screen, false) catch {};

        std.posix.tcsetattr(self.fin.file.handle, .FLUSH, self.original_termios) catch {};
        gpa.free(self.cells);
        gpa.free(self.in.buffer.ptr[0 .. 2 * self.in.buffer.len]);
    }

    pub fn set(self: *Screen, feature: Feature, enabled: bool) !void {
        try self.out.print("\x1b[?{d}{c}", .{ @intFromEnum(feature), @as(u8, if (enabled) 'h' else 'l') });
        try self.out.flush();
    }

    pub fn refresh(self: *Screen, gpa: std.mem.Allocator) !void {
        const size = try self.querySizeIoctl();
        if (size[0] != self.width or size[1] != self.height) {
            self.width = size[0];
            self.height = size[1];
            const total: usize = @intCast(self.width * self.height);
            self.cells = try gpa.realloc(self.cells, total);
        }
    }

    pub fn clear(self: *Screen) void {
        @memset(self.cells, Cell{});
    }

    pub fn draw(self: *Screen, x: i32, y: i32, z: i32, bytes: []const u8, fg: Color) void {
        if (y < 0 or y >= self.height) return;

        var col = x;
        const view: std.unicode.Utf8View = .initUnchecked(bytes);
        var it = view.iterator();

        while (it.nextCodepoint()) |cp| : (col += 1) {
            if (col >= self.width) break;
            const idx: usize = @intCast(y * self.width + col);
            if (z < self.cells[idx].z) continue;
            self.cells[idx].char = cp;
            self.cells[idx].fg = fg;
            self.cells[idx].z = z;
        }
    }

    pub fn splat(self: *Screen, x: i32, y: i32, z: i32, bytes: []const u8, n: i32, fg: Color) void {
        if (n <= 0) return;
        const view = std.unicode.Utf8View.initUnchecked(bytes);
        var it = view.iterator();
        var stride: i32 = 0;
        while (it.nextCodepoint() != null) stride += 1;
        if (stride == 0) return;
        var rep: i32 = 0;
        while (rep < n) : (rep += 1) {
            self.draw(x + rep * stride, y, z, bytes, fg);
        }
    }

    pub fn fill(self: *Screen, x: i32, y: i32, z: i32, w: i32, bg: Color) void {
        if (y < 0 or y >= self.height or w <= 0) return;

        const row_start: usize = @intCast(y * self.width);
        const start = @max(x, 0);
        const end = @min(x + w, self.width);
        if (start >= end) return;

        for (@as(usize, @intCast(start))..@as(usize, @intCast(end))) |col| {
            if (z < self.cells[row_start + col].z) continue;
            self.cells[row_start + col] = .{ .bg = bg, .z = z };
        }
    }

    pub fn flush(self: *Screen) !void {
        const w: usize = @intCast(self.width);
        const h: usize = @intCast(self.height);

        var cur_fg: Color = .white;
        var cur_bg: Color = .black;

        for (0..h) |row| {
            // Move cursor to start of row to contain wide-char layout damage (single emoji ruining layout for the whole app)
            try self.out.print(ansi.csi ++ "{d};1H", .{row + 1});

            const row_start = row * w;
            for (0..w) |col| {
                const cell = self.cells[row_start + col];

                // Emit color changes only when needed
                if (cell.fg != cur_fg or cell.bg != cur_bg) {
                    if (self.truecolor) {
                        try self.out.print(ansi.csi ++ "38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ cell.fg.r(), cell.fg.g(), cell.fg.b(), cell.bg.r(), cell.bg.g(), cell.bg.b() });
                    } else {
                        try self.out.print(ansi.csi ++ "38;5;{d};48;5;{d}m", .{ cell.fg.to256(), cell.bg.to256() });
                    }
                    cur_fg = cell.fg;
                    cur_bg = cell.bg;
                }

                // Encode u21 codepoint to UTF-8
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
                try self.out.writeAll(buf[0..len]);
            }
        }

        // Reset colors
        try self.out.writeAll(ansi.csi ++ "39;49m");
        try self.out.flush();
    }

    fn querySizeIoctl(self: *Screen) ![2]i32 {
        const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        var ws: Winsize = undefined;
        const TIOCGWINSZ: c_int = 0x40087468;
        if (std.c.ioctl(self.fout.file.handle, TIOCGWINSZ, &ws) != 0) return error.IoctlFailed;
        return .{ @intCast(ws.ws_col), @intCast(ws.ws_row) };
    }
};
