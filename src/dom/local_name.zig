const std = @import("std");
const util = @import("../util.zig");

// TODO: arbitrary tag names/attributes (len > 12)
pub const LocalName = enum(u128) {
    _, // tk.util.Smol128

    // Shorthand for usage in switch statements
    const p = parse;

    pub fn parse(local_name: []const u8) LocalName {
        const x = util.Smol128.initShort(local_name) orelse util.Smol128.initComptime("unknown");
        return @enumFromInt(x.raw);
    }

    pub fn name(self: *const LocalName) []const u8 {
        return util.Smol128.str(@ptrCast(self));
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
