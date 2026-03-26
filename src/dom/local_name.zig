const std = @import("std");
const ShortString = @import("../string.zig").ShortString;

// TODO: arbitrary tag names/attributes (len > 15)
pub const LocalName = enum(u128) {
    _, // tk.ShortString

    // Shorthand for usage in switch statements
    const p = parse;

    pub fn parse(local_name: []const u8) LocalName {
        const x = ShortString.init(local_name) orelse ShortString.initComptime("unknown");
        const raw: u128 = @bitCast(x);
        return @enumFromInt(raw);
    }

    pub fn name(self: *const LocalName) []const u8 {
        return ShortString.str(@ptrCast(self));
    }

    pub fn isVoid(self: LocalName) bool {
        return switch (self) {
            p("area"), p("base"), p("br"), p("col"), p("embed"), p("frame"), p("hr"), p("img"), p("input"), p("isindex"), p("keygen"), p("link"), p("meta"), p("param"), p("source"), p("track"), p("wbr") => true,
            else => false,
        };
    }

    pub fn isRaw(self: LocalName) bool {
        return switch (self) {
            p("script"), p("style") => true,
            else => false,
        };
    }
};
