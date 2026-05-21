const util = @import("../util.zig");
const Screen = @import("screen.zig").Screen;
const Color = @import("color.zig").Color;

pub const Border = struct {
    parts: [8][]const u8,

    /// Create a border using custom parts (north-west, north, north-east, ...)
    pub fn nesw(parts: [8][]const u8) Border {
        return .{ .parts = parts };
    }

    pub const all = nesw(.{ "┌", "─", "┐", "│", "┘", "─", "└", "│" });
    pub const top = nesw(.{ "─", "─", "─", "", "", "", "", "" });
    pub const right = nesw(.{ "", "", "│", "│", "│", "", "", "" });
    pub const bottom = nesw(.{ "", "", "", "", "─", "─", "─", "" });
    pub const left = nesw(.{ "│", "", "", "", "", "", "│", "│" });
};

pub const Frame = struct {
    screen: *Screen,
    rect: [4]i32, // absolute x, y, w, h
    fg: Color = .white,
    z: i8 = 0,

    /// Return a copy of self with one field replaced.
    pub fn with(self: Frame, comptime field: []const u8, value: @FieldType(Frame, field)) Frame {
        var copy = self;
        @field(copy, field) = value;
        return copy;
    }

    /// True if the frame has zero or negative dimensions.
    pub fn empty(self: Frame) bool {
        return self.rect[2] <= 0 or self.rect[3] <= 0;
    }

    /// Frame width in columns.
    pub fn width(self: Frame) i32 {
        return self.rect[2];
    }

    /// Frame height in rows.
    pub fn height(self: Frame) i32 {
        return self.rect[3];
    }

    /// Sub-frame at relative (x, y) with given size, clamped to self.
    pub fn sub(self: Frame, x: i32, y: i32, w: i32, h: i32) Frame {
        const ax = self.rect[0] + x;
        const ay = self.rect[1] + y;
        const cw = @min(w, self.rect[0] + self.rect[2] - ax);
        const ch = @min(h, self.rect[1] + self.rect[3] - ay);
        return self.with("rect", .{ ax, ay, cw, ch });
    }

    /// Sub-frame at relative (x, y) with the same size.
    pub fn at(self: Frame, x: i32, y: i32) Frame {
        return self.sub(x, y, self.rect[2], self.rect[3]);
    }

    /// Shift the frame origin by (x, y) without clamping.
    pub fn offset(self: Frame, x: i32, y: i32) Frame {
        return self.with("rect", .{ self.rect[0] + x, self.rect[1] + y, self.rect[2], self.rect[3] });
    }

    /// Adjust all four sides; positive = shrink, negative = grow.
    /// sides = [top, right, bottom, left]
    pub fn pad(self: Frame, sides: [4]i32) Frame {
        return self.with("rect", .{ self.rect[0] + sides[3], self.rect[1] + sides[0], self.rect[2] - sides[1] - sides[3], self.rect[3] - sides[0] - sides[2] });
    }

    /// Narrow to width `w`, anchored to the left edge.
    pub fn left(self: Frame, w: i32) Frame {
        return self.sub(0, 0, w, self.rect[3]);
    }

    /// Narrow to width `w`, anchored to the right edge.
    pub fn right(self: Frame, w: i32) Frame {
        return self.sub(self.rect[2] - w, 0, w, self.rect[3]);
    }

    /// Narrow to height `h`, anchored to the top edge.
    pub fn top(self: Frame, h: i32) Frame {
        return self.sub(0, 0, self.rect[2], h);
    }

    /// Narrow to height `h`, anchored to the bottom edge.
    pub fn bottom(self: Frame, h: i32) Frame {
        return self.sub(0, self.rect[3] - h, self.rect[2], h);
    }

    /// Narrow to width `w`, centered horizontally.
    pub fn hcenter(self: Frame, w: i32) Frame {
        return self.sub(@divTrunc(self.rect[2] - w, 2), 0, w, self.rect[3]);
    }

    /// Narrow to height `h`, centered vertically.
    pub fn vcenter(self: Frame, h: i32) Frame {
        return self.sub(0, @divTrunc(self.rect[3] - h, 2), self.rect[2], h);
    }

    /// Narrow to `w`×`h`, centered on both axes.
    pub fn center(self: Frame, w: i32, h: i32) Frame {
        return self.sub(@divTrunc(self.rect[2] - w, 2), @divTrunc(self.rect[3] - h, 2), w, h);
    }

    /// Draw a chunk once at (x, y).
    pub fn draw(self: Frame, x: i32, y: i32, chunk: []const u8) void {
        self.screen.draw(self.rect[0] + x, self.rect[1] + y, self.z, chunk, self.fg);
    }

    /// Draw one frame of an animation, cycling by `tick`.
    pub fn drawAnim(self: Frame, x: i32, y: i32, frames: []const []const u8, tick: u64) void {
        self.draw(x, y, frames[tick % frames.len]);
    }

    /// Draw text at the frame's origin, clipped to frame width.
    /// If the frame is taller than one row, renders multiple lines with
    /// wrapping at width and honoring '\n'.
    pub fn text(self: Frame, str: []const u8) void {
        if (self.rect[2] <= 0 or self.rect[3] <= 0) return;

        var it = util.wordWrap(str, @intCast(self.rect[2]));
        var row: i32 = 0;
        while (row < self.rect[3]) : (row += 1) {
            self.draw(0, row, it.next() orelse return);
        }
    }

    /// Fill the entire frame background.
    pub fn fill(self: Frame, bg: Color) void {
        var row: i32 = 0;
        while (row < self.rect[3]) : (row += 1) {
            self.screen.fill(self.rect[0], self.rect[1] + row, self.z, self.rect[2], bg);
        }
    }

    /// Fill the entire frame by repeating a chunk per cell (foreground only).
    pub fn splat(self: Frame, chunk: []const u8) void {
        var row: i32 = 0;
        while (row < self.rect[3]) : (row += 1) {
            self.screen.splat(self.rect[0], self.rect[1] + row, self.z, chunk, self.rect[2], self.fg);
        }
    }

    /// Draw a horizontal line of `─` characters.
    pub fn hline(self: Frame, x: i32, y: i32, len: i32) void {
        self.sub(x, y, len, 1).splat("─");
    }

    /// Draw a vertical line of `│` characters.
    pub fn vline(self: Frame, x: i32, y: i32, len: i32) void {
        self.sub(x, y, 1, len).splat("│");
    }

    pub fn border(self: Frame, bord: Border) void {
        const p = &bord.parts;
        const w = self.rect[2];
        const h = self.rect[3];

        // Draw corners
        if (p[0].len > 0) self.draw(0, 0, p[0]);
        if (p[2].len > 0) self.draw(w - 1, 0, p[2]);
        if (p[4].len > 0) self.draw(w - 1, h - 1, p[4]);
        if (p[6].len > 0) self.draw(0, h - 1, p[6]);

        // Draw middle parts for top/bottom
        if (p[1].len > 0) self.hline(1, 0, w - 2);
        if (p[5].len > 0) self.hline(1, h - 1, w - 2);

        // And also for left/right
        if (p[3].len > 0) self.vline(0, 1, h - 2);
        if (p[7].len > 0) self.vline(w - 1, 1, h - 2);
    }

    /// Draw a drop shadow (1-cell offset, bottom and right).
    pub fn shadow(self: Frame) void {
        const s = self.offset(1, 1);
        s.bottom(1).fill(.black);
        s.right(1).fill(.black);
    }

    /// Fill the left `v` fraction of the frame (0.0..1.0).
    pub fn hbar(self: Frame, v: f32, bg: Color) void {
        const filled: i32 = @intFromFloat(@as(f32, @floatFromInt(self.rect[2])) * @max(0.0, @min(1.0, v)));
        self.left(filled).fill(bg);
    }

    /// Fill the bottom `v` fraction of the frame (0.0..1.0).
    pub fn vbar(self: Frame, v: f32, bg: Color) void {
        const filled: i32 = @intFromFloat(@as(f32, @floatFromInt(self.rect[3])) * @max(0.0, @min(1.0, v)));
        self.bottom(filled).fill(bg);
    }
};
