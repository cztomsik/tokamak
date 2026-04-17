const std = @import("std");
const ansi = @import("../ansi.zig");

pub const Cell = struct {
    char: u21 = ' ',
    fg: ansi.Color = .default,
    bg: ansi.Color = .default,
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

        // Query initial terminal size and allocate cell buffer
        const size = try self.querySizeIoctl();
        self.width = size[0];
        self.height = size[1];
        const total: usize = @intCast(self.width * self.height);
        self.cells = try gpa.alloc(Cell, total);
        @memset(self.cells, Cell{});

        try self.out.writeAll("\x1b[?1049h\x1b[?2004h\x1b[?25l");
        try self.out.flush();
    }

    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        self.out.writeAll("\x1b[?25h\x1b[?2004l\x1b[?1049l") catch {};
        self.out.flush() catch {};
        std.posix.tcsetattr(self.fin.file.handle, .FLUSH, self.original_termios) catch {};
        gpa.free(self.cells);
        gpa.free(self.in.buffer.ptr[0 .. 2 * self.in.buffer.len]);
    }

    pub fn clear(self: *Screen) void {
        @memset(self.cells, Cell{});
    }

    // TODO: We should also add draw() for regular drawing (without repetition)
    //       and then we could probably even decrese the buffer size here
    //       and we could even consider using tk.ShortString instead for splats
    //       and maybe we could use ShortString even instead of the codepoint itself
    //       then we could avoid decoding/re-encoding and just update correct cells
    pub fn splat(self: *Screen, x: i32, y: i32, bytes: []const u8, n: i32, fg: ansi.Color) void {
        if (y < 0 or y >= self.height or n <= 0) return;

        // Decode codepoints from bytes
        var codepoints: [256]u21 = undefined;
        var cp_len: usize = 0;
        const view = std.unicode.Utf8View.initUnchecked(bytes);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp_len >= codepoints.len) break;
            codepoints[cp_len] = cp;
            cp_len += 1;
        }
        if (cp_len == 0) return;

        const row_start: usize = @intCast(y * self.width);
        var col = x;
        var rep: i32 = 0;
        while (rep < n) : (rep += 1) {
            for (codepoints[0..cp_len]) |cp| {
                if (col >= 0 and col < self.width) {
                    const idx = row_start + @as(usize, @intCast(col));
                    self.cells[idx].char = cp;
                    self.cells[idx].fg = fg;
                }
                col += 1;
            }
        }
    }

    pub fn fill(self: *Screen, x: i32, y: i32, w: i32, bg: ansi.Color) void {
        if (y < 0 or y >= self.height or w <= 0) return;

        const row_start: usize = @intCast(y * self.width);
        const start = @max(x, 0);
        const end = @min(x + w, self.width);
        if (start >= end) return;

        for (@as(usize, @intCast(start))..@as(usize, @intCast(end))) |col| {
            self.cells[row_start + col].bg = bg;
        }
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

    pub fn flush(self: *Screen) !void {
        const w: usize = @intCast(self.width);
        const h: usize = @intCast(self.height);

        // Cursor home
        try self.out.writeAll(ansi.cp);

        var cur_fg: ansi.Color = .default;
        var cur_bg: ansi.Color = .default;

        for (0..h) |row| {
            const row_start = row * w;
            for (0..w) |col| {
                const cell = self.cells[row_start + col];

                // Emit color changes only when needed
                if (cell.fg != cur_fg or cell.bg != cur_bg) {
                    try self.out.print(ansi.csi ++ "{d};{d}m", .{ @intFromEnum(cell.fg), @intFromEnum(cell.bg) + 10 });
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
