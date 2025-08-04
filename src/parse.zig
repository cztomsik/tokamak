const std = @import("std");
const meta = @import("meta.zig");

/// Parse a string value into the requested type.
/// Supports: optional, bool, int, enum, string, and slices (comma-separated).
pub fn parseValue(comptime T: type, s: []const u8, arena: std.mem.Allocator) !T {
    if (std.meta.hasFn(T, "parse")) {
        return T.parse(s);
    }

    return switch (@typeInfo(T)) {
        .bool => std.mem.eql(u8, s, "true"),
        .int => std.fmt.parseInt(T, s, 10),
        .float => std.fmt.parseFloat(T, s),
        .@"enum" => std.meta.stringToEnum(T, s) orelse error.InvalidEnumTag,
        .optional => |o| if (std.mem.eql(u8, s, "null")) null else try parseValue(o.child, s, arena),
        .pointer => |p| {
            if (meta.isString(T)) return s;

            if (p.size == .slice) {
                if (s.len == 0) return &.{};
                const items = try arena.alloc(p.child, std.mem.count(u8, s, ",") + 1);
                var parts = std.mem.splitScalar(u8, s, ',');
                for (items) |*it| it.* = try parseValue(p.child, parts.next().?, arena);
                return items;
            }

            @compileError("Unsupported pointer type for parsing");
        },
        else => @compileError("Unsupported type for parsing: " ++ @typeName(T)),
    };
}

fn expectParse(comptime T: type, input: []const u8, expected: T) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualDeep(expected, try parseValue(T, input, arena.allocator()));
}

test {
    try expectParse(bool, "true", true);
    try expectParse(u32, "123", 123);
    try expectParse(i32, "-123", -123);
    try expectParse(f32, "3.14", 3.14);
    try expectParse(enum { foo, bar }, "bar", .bar);
    try expectParse([]const u8, "hello", "hello");

    // optional
    try expectParse(?u32, "null", null);
    try expectParse(?u32, "12", 12);

    // slices
    try expectParse([]const u32, "", &.{});
    try expectParse([]const u32, "1", &.{1});
    try expectParse([]const u32, "1,2,3", &.{ 1, 2, 3 });
    try expectParse([]const []const u8, "foo,bar,baz", &.{ "foo", "bar", "baz" });
}
