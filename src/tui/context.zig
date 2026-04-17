const std = @import("std");
const input = @import("input.zig");
const Screen = @import("screen.zig").Screen;
const Frame = @import("frame.zig").Frame;
const Builder = @import("builder.zig").Builder;

const N_MAX_DEPTH = 16;
const N_MAX_COLS = 16;
const N_MAX_CONTROLS = 64;

pub const Key = input.Key;

// Encode percentage as fixed-point value below -100_000
pub fn perc(v: f32) i32 {
    return @intFromFloat(v * -1_000_000);
}

pub fn cols(comptime n: u8) []const i32 {
    const percs: [n]i32 = @splat(perc(100.0 / @as(f32, @floatFromInt(n))));
    return &percs;
}

pub fn resolve(n: i32, total: i32, rem: i32) i32 {
    if (n >= 0) return n; // abs
    if (n == -1) return rem; // fill all
    if (n <= -100_000) return @divTrunc(@divTrunc(-n, 100_000) * total, 1000); // percentage
    return rem + n - 1; // N from the right edge
}

pub const Layout = struct {
    widths: [N_MAX_COLS]i32 = @splat(-1),
    n_widths: u8 = 1,
    spacing: i32 = 1,
    cursor: [2]i32 = .{ 0, 0 },
    row_height: i32 = 0,
};

pub const Container = struct {
    id: u8 = 0,
    frame: Frame,
    index: usize = 0,
    layout: Layout = .{},

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

    pub fn peek(self: *Container) ?i32 {
        if (self.layout.n_widths == 0) return null;
        const col = self.index % self.layout.n_widths;
        const at_wrap = col == 0 and self.index > 0;
        return resolve(self.layout.widths[col], self.frame.rect[2], self.frame.rect[2] - if (at_wrap) @as(i32, 0) else self.layout.cursor[0]);
    }

    pub fn next(self: *Container, height: i32) ?Frame {
        if (self.layout.n_widths == 0) return null;
        const col = self.index % self.layout.n_widths;

        if (col == 0 and self.index > 0) {
            self.layout.cursor[1] += self.layout.row_height + self.layout.spacing;
            self.layout.cursor[0] = 0;
            self.layout.row_height = 0;
        }

        const res: [4]i32 = .{
            self.frame.rect[0] + self.layout.cursor[0],
            self.frame.rect[1] + self.layout.cursor[1],
            resolve(self.layout.widths[col], self.frame.rect[2], self.frame.rect[2] - self.layout.cursor[0]),
            resolve(height, self.frame.rect[3], self.frame.rect[3] - self.layout.cursor[1]),
        };

        self.index += 1;
        self.layout.cursor[0] += res[2] + self.layout.spacing;
        self.layout.row_height = @max(self.layout.row_height, res[3]);

        if (res[2] <= 0 or res[3] <= 0) return null;

        return self.frame.with("rect", res);
    }
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    screen: Screen,
    stack: [N_MAX_DEPTH]Container,
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
