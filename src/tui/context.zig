const std = @import("std");
const Color = @import("../ansi.zig").Color;
const input = @import("input.zig");
const Screen = @import("screen.zig").Screen;
const Frame = @import("frame.zig").Frame;
const Builder = @import("builder.zig").Builder;

const N_MAX_DEPTH = 16;
const N_MAX_COLS = 16;
const N_MAX_CONTROLS = 64;

pub const Key = input.Key;

/// Encode percentage as fixed-point value below -100_000
pub fn perc(v: f32) i32 {
    return @intFromFloat(v * -1_000_000);
}

pub fn resolve(n: i32, total: i32, rem: i32) i32 {
    if (n >= 0) return n; // abs
    if (n == -1) return rem; // fill all
    if (n <= -100_000) return @divTrunc(@divTrunc(-n, 100_000) * total, 1000); // percentage
    return rem + n - 1; // N from the right edge
}

test {
    try std.testing.expectEqual(12, resolve(12, 100, 100));
    try std.testing.expectEqual(33, resolve(perc(100.0 / 3.0), 100, 100));
}

pub const Layout = struct {
    widths: [N_MAX_COLS]i32 = @splat(-1),
    n_widths: u8 = 1,
    spacing: i32 = 1,
    cursor: [2]i32 = .{ 0, 0 },
    line_height: i32 = 0,
};

pub const Container = struct {
    id: u8 = 0,
    frame: Frame,
    index: usize = 0,
    layout: Layout = .{},

    /// Claim next cell and set up a new child container. NOTE that it is only
    /// valid until the next push() at the same depth overwrites it.
    pub fn push(self: *Container, widths: []const i32, height: i32) ?*Container {
        if ((self.id + 1) >= N_MAX_DEPTH) return null;
        const new = &@as([*]Container, @ptrCast(self))[1];

        new.* = .{
            .id = self.id + 1,
            .frame = self.next(height) orelse return null,
            .layout = .{ .n_widths = @intCast(widths.len), .spacing = self.layout.spacing },
        };
        @memcpy(new.layout.widths[0..widths.len], widths);

        return new;
    }

    /// Like push(), but for N equal-sized columns.
    pub fn pushEq(self: *Container, n: u8, height: i32) ?*Container {
        const new = self.push(&.{}, height) orelse return null;
        new.layout.n_widths = n;
        @memset(new.layout.widths[0..n], perc(100.0 / @as(f32, @floatFromInt(n))));
        return new;
    }

    /// Get resolved rect of the next cell without advancing the cursor.
    pub fn peek(self: *Container, height: i32) ?[4]i32 {
        const col = self.index % self.layout.n_widths;
        const wrap = col == 0 and self.index > 0;
        const cx = if (wrap) @as(i32, 0) else self.layout.cursor[0];
        const cy = self.layout.cursor[1] + if (wrap) self.layout.line_height + self.layout.spacing else @as(i32, 0);
        const w = resolve(self.layout.widths[col], self.frame.rect[2], self.frame.rect[2] - cx);
        const h = resolve(height, self.frame.rect[3], self.frame.rect[3] - cy);

        if (w <= 0 or h <= 0) return null;
        return .{ self.frame.rect[0] + cx, self.frame.rect[1] + cy, w, h };
    }

    /// Advance the cursor and returns the next cell Frame.
    pub fn next(self: *Container, height: i32) ?Frame {
        const rect = self.peek(height) orelse return null;
        self.layout.cursor[0] = rect[0] - self.frame.rect[0] + rect[2] + self.layout.spacing;
        self.layout.cursor[1] = rect[1] - self.frame.rect[1];
        self.layout.line_height = @max(if (self.index % self.layout.n_widths == 0) @as(i32, 0) else self.layout.line_height, rect[3]);
        self.index += 1;
        return self.frame.with("rect", rect);
    }
};

test Container {
    var stack: [2]Container = @splat(.{ .frame = .{ .rect = .{ 0, 0, 100, 100 }, .screen = undefined } });
    const row = stack[0].pushEq(4, 1).?;
    try std.testing.expectEqual(.{ 0, 0, 25, 1 }, row.next(1).?.rect);
}

pub const Theme = extern struct {
    fg: Color = .black,
    bg: Color = .default,
    accent: Color = .cyan,
    focus: Color = .blue,
    active: Color = .white,

    pub const dark: Theme = @bitCast([5]Color{ .white, .black, .blue, .cyan, .white });
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    screen: Screen,
    stack: [N_MAX_DEPTH]Container,
    theme: Theme = .{},
    focus: u32 = 0,
    n_controls: u32 = 0,
    last_key: ?Key = null,
    frame: u64 = 0,
    cursors: [N_MAX_CONTROLS]usize = @splat(std.math.maxInt(usize)),

    pub fn init(gpa: std.mem.Allocator) !*Context {
        const ctx = try gpa.create(Context);
        errdefer gpa.destroy(ctx);

        ctx.* = .{ .gpa = gpa, .screen = undefined, .stack = undefined };
        try ctx.screen.init(gpa);

        return ctx;
    }

    pub fn deinit(self: *Context) void {
        const gpa = self.gpa;
        self.screen.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn beginFrame(self: *Context) !Builder {
        try self.screen.refresh(self.gpa);
        self.screen.clear();

        self.stack[0] = .{ .frame = .{ .screen = &self.screen, .rect = .{ 0, 0, self.screen.width, self.screen.height } } };
        self.n_controls = 0;
        self.frame += 1;

        return .{
            .ctx = self,
            .frame = &self.stack[0].frame,
        };
    }

    pub fn endFrame(self: *Context) !void {
        try self.screen.flush();
    }

    pub fn readKey(self: *Context) !Key {
        return input.readKey(self.screen.in);
    }
};
