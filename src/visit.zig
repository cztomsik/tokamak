// This is both subtly broken and unfinished. The idea here is that it should be
// useful enough for implementing arbitrary content-type renderers without
// having to go through all of that type sniffing which is usually needed.
//
// BUT - I have no idea if that will (or can) actually work out. It's just a
// tiny fun experiment at the moment and if it turns out to be useful, it's
// likely that the API will need to change significantly, so don't dependend on
// this.
//
// Here's where I think it might be useful:
// - yaml, json, xml, csv
// - binary (protobuf, bincode, ?)
// - debug, testing, CLI prints
// - templates (if we can walk the model, we can also "push" refs/values to be later used by the template)

const std = @import("std");
const meta = @import("meta.zig");

pub const Edge = union(enum) {
    void,
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,

    begin_struct: usize, // fields.len
    field: []const u8,
    end_struct,

    begin_array: usize, // len
    end_array,
};

const EdgeKind = std.meta.Tag(Edge);

pub fn visit(val: anytype, cx: anytype, handler: *const fn (@TypeOf(cx), Edge) anyerror!void) anyerror!void {
    const T = @TypeOf(val);

    if (meta.isString(T)) {
        return handler(cx, .{ .string = val });
    }

    if (meta.isSlice(T)) {
        try handler(cx, .{ .begin_array = val.len });

        for (val) |item| {
            try visit(item, cx, handler);
        }

        return handler(cx, .end_array);
    }

    if (meta.isStruct(T)) {
        const fields = std.meta.fields(T);

        try handler(cx, .{ .begin_struct = fields.len });

        inline for (fields) |f| {
            try handler(cx, .{ .field = f.name });
            try visit(@field(val, f.name), cx, handler);
        }

        return handler(cx, .end_struct);
    }

    switch (@typeInfo(T)) {
        .void => try handler(cx, .void),
        .null => try handler(cx, .null),
        .bool => try handler(cx, .{ .bool = val }),
        .int, .comptime_int => try handler(cx, .{ .int = @intCast(val) }),
        .float, .comptime_float => try handler(cx, .{ .float = @floatCast(val) }),
        .@"enum", .enum_literal => try handler(cx, .{ .string = @tagName(val) }),
        .error_set => try handler(cx, .{ .string = @errorName(val) }),
        .optional => if (val) |v| try visit(v, cx, handler) else try handler(cx, .null),
        .array => |a| try visit(@as([]const a.child, &val), cx, handler),
        .pointer => try visit(val.*, cx, handler),
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

fn expectEdges(value: anytype, edges: []const EdgeKind) !void {
    var buf = std.ArrayList(EdgeKind).init(std.testing.allocator);
    defer buf.deinit();

    const H = struct {
        fn append(list: *std.ArrayList(EdgeKind), edge: Edge) !void {
            try list.append(edge);
        }
    };

    try visit(value, &buf, H.append);
    try std.testing.expectEqualDeep(edges, buf.items);
}

const Person = struct { name: []const u8, age: u32 };
const people: []const Person = &.{.{ .name = "John", .age = 32 }};

test {
    try expectEdges({}, &.{.void});
    try expectEdges(null, &.{.null});
    try expectEdges(true, &.{.bool});
    try expectEdges(123, &.{.int});
    try expectEdges(1.23, &.{.float});
    try expectEdges("hello", &.{.string});
    try expectEdges(.{ .msg = "Hello" }, &.{ .begin_struct, .field, .string, .end_struct });
    try expectEdges(&[_]u32{ 1, 2, 3 }, &.{ .begin_array, .int, .int, .int, .end_array });
    try expectEdges(people[0], &.{ .begin_struct, .field, .string, .field, .int, .end_struct });
    try expectEdges(people, &.{ .begin_array, .begin_struct, .field, .string, .field, .int, .end_struct, .end_array });
}
