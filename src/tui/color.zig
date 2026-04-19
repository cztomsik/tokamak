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

    pub fn r(self: Color) u8 {
        return @truncate(@intFromEnum(self) >> 16);
    }

    pub fn g(self: Color) u8 {
        return @truncate(@intFromEnum(self) >> 8);
    }

    pub fn b(self: Color) u8 {
        return @truncate(@intFromEnum(self));
    }

    /// Map to nearest 256-color index (6×6×6 cube or grayscale ramp)
    pub fn to256(self: Color) u8 {
        const cr, const cg, const cb = .{ self.r(), self.g(), self.b() };

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

test {
    const c = Color.rgb(0xCC, 0xCA, 0xC2);
    try std.testing.expectEqual(@as(u8, 251), c.to256());
}
