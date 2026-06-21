const std = @import("std");

pub const Color = enum(u32) {
    black = 0x000000,
    red = 0xCD0000,
    green = 0x00CD00,
    yellow = 0xCDCD00,
    blue = 0x0000EE,
    magenta = 0xCD00CD,
    cyan = 0x00CDCD,
    white = 0xE5E5E5,
    _,

    /// True RGB color
    pub fn rgb(red: u8, green: u8, blue: u8) Color {
        return @enumFromInt(@as(u32, red) << 16 | @as(u32, green) << 8 | blue);
    }

    pub fn toRGB(self: Color) [3]u8 {
        const v = @intFromEnum(self);
        return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
    }

    pub fn format(self: Color, writer: anytype) !void {
        const r, const g, const b = self.toRGB();
        try writer.print("{d};{d};{d}", .{ r, g, b });
    }

    /// Map to nearest 256-color index (6×6×6 cube or grayscale ramp)
    pub fn to256(self: Color) u8 {
        const cr, const cg, const cb = self.toRGB();

        // Nearest in the 6×6×6 color cube
        const qr, const qg, const qb = .{ cubeLevel(cr), cubeLevel(cg), cubeLevel(cb) };
        const cube_idx = 16 + @as(u8, qr) * 36 + @as(u8, qg) * 6 + qb;
        const cube_d = sqDist(cr, cg, cb, cubeVal(qr), cubeVal(qg), cubeVal(qb));

        // Nearest in the 24-step grayscale ramp (232–255)
        const avg: u8 = @intCast((@as(u16, cr) + cg + cb) / 3);
        const gi: u8 = if (avg > 238) 23 else if (avg < 13) 0 else @intCast((@as(u16, avg) - 3) / 10);
        const gv: u8 = @intCast(8 + @as(u16, gi) * 10);
        const gray_d = sqDist(cr, cg, cb, gv, gv, gv);

        return if (gray_d < cube_d) 232 + gi else cube_idx;
    }

    fn cubeLevel(v: u8) u8 {
        if (v < 48) return 0;
        if (v < 115) return 1;
        if (v < 155) return 2;
        if (v < 195) return 3;
        if (v < 235) return 4;
        return 5;
    }

    fn cubeVal(l: u8) u8 {
        if (l == 0) return 0;
        return @as(u8, l) * 40 + 55;
    }

    fn sqDist(r1: u8, g1: u8, b1: u8, r2: u8, g2: u8, b2: u8) u32 {
        const dr: i32 = @as(i32, r1) - r2;
        const dg: i32 = @as(i32, g1) - g2;
        const db: i32 = @as(i32, b1) - b2;
        return @intCast(dr * dr + dg * dg + db * db);
    }
};

/// Named theme color slots. Cells reference these by index instead of raw RGB.
pub const ThemeColor = enum(u8) {
    text = 0, // default text
    base1 = 1, // base bg
    base2 = 2, // darker (elevation/nesting)
    base3 = 3, // darkest
    primary = 4, // primary action
    secondary = 5,
    accent = 6,

    pub fn resolve(self: ThemeColor, theme: *const Theme) Color {
        return @as(*const [7]Color, @ptrCast(theme))[@intFromEnum(self)];
    }
};

/// Screen-owned theme: 7 named color slots.
pub const Theme = extern struct {
    text: Color,
    base1: Color,
    base2: Color,
    base3: Color,
    primary: Color,
    secondary: Color,
    accent: Color,

    pub const nord: Theme = @bitCast([7]u32{ 0xECEFF4, 0x2E3440, 0x3B4252, 0x434C5E, 0x88C0D0, 0x81A1C1, 0xA3BE8C });
    pub const dracula: Theme = @bitCast([7]u32{ 0xF8F8F2, 0x282A36, 0x343746, 0x424450, 0xBD93F9, 0x6272A4, 0x8BE9FD });
    pub const ayu_mirage: Theme = @bitCast([7]u32{ 0xCCCAC2, 0x1F2430, 0x232834, 0x2A2F3A, 0x5CCFE6, 0xAAD94C, 0xFFCC66 });
    pub const catppuccin_mocha: Theme = @bitCast([7]u32{ 0xCDD6F4, 0x1E1E2E, 0x181825, 0x11111B, 0x89B4FA, 0xB4BEFE, 0xF5C2E7 });
    pub const catppuccin_latte: Theme = @bitCast([7]u32{ 0x4C4F69, 0xEFF1F5, 0xE6E9EF, 0xDCE0E8, 0x1E66F5, 0x7287FD, 0xEA76CB });
};

test {
    const c = Color.rgb(0xCC, 0xCA, 0xC2);
    try std.testing.expectEqual(@as(u8, 251), c.to256());
}

test "ThemeColor.resolve(&theme)" {
    try std.testing.expectEqual(Theme.nord.text, ThemeColor.resolve(.text, &Theme.nord));
    try std.testing.expectEqual(Theme.nord.primary, ThemeColor.resolve(.primary, &Theme.nord));
}
