const std = @import("std");
const Color = @import("color.zig").Color;

pub const Feature = enum(u32) {
    /// Use a separate screen buffer so the app doesn't overwrite the shell
    alternate_screen = 1049,
    /// Allow pasting text safely without it being interpreted as keypresses
    bracketed_paste = 2004,
    /// Report mouse button press/release events
    mouse_buttons = 1000,
    /// Report mouse drag events (movement while button is held)
    mouse_drag = 1002,
    /// Report all mouse movement events, even if no button is pressed
    mouse_any = 1003,
    /// Use SGR mouse encoding so coordinates are unbounded and explicit
    mouse_sgr = 1006,
    /// Show the terminal cursor
    show_cursor = 25,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .white,
    bg: Color = .black,
    z: i32 = 0,
};

pub const Buffer = struct {
    size: [2]i32,
    cells: []Cell,

    pub fn init(gpa: std.mem.Allocator, size: [2]i32) !Buffer {
        const cells = try gpa.alloc(Cell, @intCast(size[0] * size[1]));
        @memset(cells, .{});
        return .{ .size = size, .cells = cells };
    }

    pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
    }

    pub fn resize(self: *Buffer, gpa: std.mem.Allocator, new_size: [2]i32) !void {
        const old_n: usize = @intCast(self.size[0] * self.size[1]);
        const new_n: usize = @intCast(new_size[0] * new_size[1]);
        self.cells = try gpa.realloc(self.cells, new_n);
        if (new_n > old_n) {
            @memset(self.cells[old_n..new_n], .{});
        }
        self.size = new_size;
    }

    pub fn clear(self: *Buffer) void {
        @memset(self.cells, .{});
    }
};

pub const Screen = struct {
    buffer: Buffer,
    fin: std.fs.File.Reader,
    fout: std.fs.File.Writer,
    original_termios: std.posix.termios,
    truecolor: bool = false,

    pub fn init(self: *Screen, gpa: std.mem.Allocator) !void {
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

        self.fin = stdin.readerStreaming(&.{});
        self.fout = std.fs.File.stdout().writerStreaming(&.{});
        self.original_termios = original;

        // Query initial terminal size and allocate cell buffer
        const size = try self.querySizeIoctl();
        self.buffer = try .init(gpa, size);

        // Enable default features
        try self.setFeature(.alternate_screen, true);
        try self.setFeature(.bracketed_paste, true);
        try self.setFeature(.mouse_buttons, true);
        try self.setFeature(.mouse_drag, true);
        try self.setFeature(.mouse_any, true);
        try self.setFeature(.mouse_sgr, true);
        try self.setFeature(.show_cursor, false);
    }

    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        // Disable features in reverse order
        self.setFeature(.show_cursor, true) catch {};
        self.setFeature(.mouse_sgr, false) catch {};
        self.setFeature(.mouse_any, false) catch {};
        self.setFeature(.mouse_drag, false) catch {};
        self.setFeature(.mouse_buttons, false) catch {};
        self.setFeature(.bracketed_paste, false) catch {};
        self.setFeature(.alternate_screen, false) catch {};

        std.posix.tcsetattr(self.fin.file.handle, .FLUSH, self.original_termios) catch {};
        self.buffer.deinit(gpa);
    }

    pub fn setFeature(self: *Screen, feat: Feature, enabled: bool) !void {
        const w = &self.fout.interface;
        try w.print("\x1b[?{d}{c}", .{ @intFromEnum(feat), @as(u8, if (enabled) 'h' else 'l') });
        try w.flush();
    }

    pub fn refresh(self: *Screen, gpa: std.mem.Allocator) !void {
        const size = try self.querySizeIoctl();
        if (size[0] != self.buffer.size[0] or size[1] != self.buffer.size[1]) {
            try self.buffer.resize(gpa, size);
        }
    }

    pub fn clear(self: *Screen) void {
        self.buffer.clear();
    }

    pub fn draw(self: *Screen, x: i32, y: i32, z: i32, bytes: []const u8, fg: Color) void {
        const w, const h = self.buffer.size;
        if (y < 0 or y >= h) return;

        var col = x;
        const view: std.unicode.Utf8View = .initUnchecked(bytes);
        var it = view.iterator();

        while (it.nextCodepoint()) |cp| : (col += 1) {
            if (col >= w) break;
            const idx: usize = @intCast(y * w + col);
            if (z < self.buffer.cells[idx].z) continue;
            self.buffer.cells[idx].char = cp;
            self.buffer.cells[idx].fg = fg;
            self.buffer.cells[idx].z = z;
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
        const bw, const bh = self.buffer.size;
        if (y < 0 or y >= bh or w <= 0) return;

        const row_start: usize = @intCast(y * bw);
        const start = @max(x, 0);
        const end = @min(x + w, bw);
        if (start >= end) return;

        for (@as(usize, @intCast(start))..@as(usize, @intCast(end))) |col| {
            if (z < self.buffer.cells[row_start + col].z) continue;
            self.buffer.cells[row_start + col] = .{ .bg = bg, .z = z };
        }
    }

    pub fn flush(self: *Screen) !void {
        const width: usize = @intCast(self.buffer.size[0]);
        const height: usize = @intCast(self.buffer.size[1]);

        var cur_fg: Color = .white;
        var cur_bg: Color = .black;

        const w = &self.fout.interface;

        for (0..height) |row| {
            // Move cursor to start of row to contain wide-char layout damage (single emoji ruining layout for the whole app)
            try w.print("\x1B[{d};1H", .{row + 1});

            const row_start = row * width;
            for (0..width) |col| {
                const cell = self.buffer.cells[row_start + col];

                // Emit color changes only when needed
                if (cell.fg != cur_fg or cell.bg != cur_bg) {
                    if (self.truecolor) {
                        try w.print("\x1B[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ cell.fg.r(), cell.fg.g(), cell.fg.b(), cell.bg.r(), cell.bg.g(), cell.bg.b() });
                    } else {
                        try w.print("\x1B[38;5;{d};48;5;{d}m", .{ cell.fg.to256(), cell.bg.to256() });
                    }
                    cur_fg = cell.fg;
                    cur_bg = cell.bg;
                }

                // Encode u21 codepoint to UTF-8
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
                try w.writeAll(buf[0..len]);
            }
        }

        // Reset colors
        try w.writeAll("\x1B[39;49m");
        try w.flush();
    }

    fn querySizeIoctl(self: *Screen) ![2]i32 {
        const TIOCGWINSZ: c_int = switch (@import("builtin").os.tag) {
            .macos, .ios, .tvos, .watchos => 0x40087468,
            .linux => 0x00005413,
            else => @compileError("unsupported OS for TIOCGWINSZ"),
        };

        const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        var ws: Winsize = undefined;
        if (std.c.ioctl(self.fout.file.handle, TIOCGWINSZ, &ws) != 0) return error.IoctlFailed;
        return .{ @intCast(ws.ws_col), @intCast(ws.ws_row) };
    }
};
