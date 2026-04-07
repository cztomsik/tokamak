const std = @import("std");
const meta = @import("meta.zig");
const testing = @import("testing.zig");

pub const csv = @import("serde/csv.zig");
pub const json = @import("serde/json.zig");
pub const table = @import("serde/table.zig");
pub const yaml = @import("serde/yaml.zig");

// NOTE: I am not sure if this is the final design, but I am 100% sure about two
// things:
//
// 1. There should be some default behavior, shared across all format-specific
//    writers, ie. how to serialize enums, tuples & tagged-unions.
//
// 2. Some types might need to customize their serialization, and there should
//    be only one such hook. I don't want to write N hooks for all supported
//    output formats.
//
// We are currently using a lot of comptime and anytype, so that yaml.zig can
// still do some type sniffing to decide if a value should be printed inline.
// The downside is that we can't switch writers at runtime.
//
// Adding a real interface could be a lot of work, and I think we might even
// need to add something like `meta.reflect(T)` for RTTI. I spent a whole day
// thinking about all various edge-cases and I couldn't think of a good API.
//
// What we have here is also a bit related to what we had in visit.zig, but I
// think it served a slightly different purpose, and it might resurface one day
// for usage with templates and/or some kind of data-binding.

pub const Error = anyerror;

pub const Kind = enum {
    void,
    null,
    bool,
    int,
    float,
    string,
    array_begin,
    array_end,
    tuple_begin,
    tuple_end,
    struct_begin,
    struct_field,
    struct_end,

    pub fn isScalar(self: Kind) bool {
        return switch (self) {
            .void, .null, .bool, .int, .float, .string => true,
            else => false,
        };
    }
};

/// Serialize a value into a series of `writer.write(kind, value)` calls.
/// Types can customize this in their `T.serialize()` hook.
///
/// The writer must implement `write(kind: Kind, value: anytype) Error!void`
/// and should call `serde.serialize()` recursively for any struct fields or
/// slice elements.
pub fn serialize(writer: anytype, value: anytype) Error!void {
    const T = @TypeOf(value);

    // Check for T.serialize(self, anytype)
    if (std.meta.hasMethod(T, "serialize")) {
        return value.serialize(writer);
    }

    // Normalize string types
    if (meta.isString(T)) {
        return writer.write(.string, @as([]const u8, value));
    }

    // Normalize everything into a series of `writer.write(kind, anytype)` calls
    return switch (@typeInfo(T)) {
        inline .void, .null, .bool, .int, .float => |_, t| writer.write(@field(Kind, @tagName(t)), value),
        .comptime_int => writer.write(.int, value),
        .comptime_float => writer.write(.float, value),
        .enum_literal => writer.write(.string, @tagName(value)),
        .@"enum" => |e| if (e.is_exhaustive) writer.write(.string, @tagName(value)) else writer.write(.int, @intFromEnum(value)),
        .error_set => writer.write(.string, @errorName(value)),
        .optional => if (value) |v| serialize(writer, v) else writer.write(.null, null),
        .error_union => if (value) |v| serialize(writer, v) else |e| serialize(writer, e),
        .array => |a| serialize(writer, @as([]const a.child, &value)),
        .@"struct" => |s| if (s.is_tuple) {
            try writer.write(.tuple_begin, value);
            inline for (0..s.fields.len) |i| try serialize(writer, value[i]);
            return writer.write(.tuple_end, {});
        } else {
            try writer.write(.struct_begin, value);
            inline for (s.fields) |f| {
                try writer.write(.struct_field, f.name);
                try serialize(writer, @field(value, f.name));
            }
            return writer.write(.struct_end, {});
        },
        .@"union" => |u| if (u.tag_type) |_| {
            switch (value) {
                inline else => |v, t| {
                    try writer.write(.struct_begin, value);
                    try writer.write(.struct_field, @tagName(t));
                    try serialize(writer, v);
                    return writer.write(.struct_end, {});
                },
            }
        } else @compileError("unsupported type: " ++ @typeName(T)),
        .pointer => |p| switch (p.size) {
            .one => serialize(writer, if (@typeInfo(p.child) == .array) @as([]const std.meta.Elem(p.child), value) else value.*),
            .slice => {
                try writer.write(.array_begin, value);
                for (value) |item| try serialize(writer, item);
                return writer.write(.array_end, {});
            },
            else => @compileError("unsupported type: " ++ @typeName(T)),
        },
        .type, .noreturn, .undefined, .@"fn", .@"opaque", .frame, .@"anyframe", .vector => @compileError("unsupported type: " ++ @typeName(T)),
    };
}
