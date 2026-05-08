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

pub const Kind = enum { void, null, bool, int, float, string };

/// Serialize a value by calling `writer.write(kind, value)` for scalar values
/// and format-specific container factories for sequences, tuples, structs and maps.
/// Types can customize this in their `T.serialize()` hook.
///
/// The writer must implement:
///
/// - `write(kind: Kind, value: anytype) Error!void` for scalar kinds
/// - `beginSeq(len: usize) Error!anytype` for slices and arrays
/// - `beginTuple(len: usize) Error!anytype` for tuple structs
/// - `beginStruct(comptime T: type, len: usize) Error!anytype` for structs and tagged unions
/// - `beginMap(len: usize) Error!anytype` for map types (detected via `KV` decl)
///
/// Sequence / tuple containers must implement:
///
/// - `element(value: anytype) Error!void`
/// - `end() Error!void`
///
/// Struct containers must implement:
///
/// - `field(key: []const u8, value: anytype) Error!void`
/// - `end() Error!void`
///
/// Map containers must implement:
///
/// - `entry(key: anytype, value: anytype) Error!void`
/// - `end() Error!void`
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

    // Detect map types
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "KV")) {
        var map = try writer.beginMap(value.count());
        var it = value.iterator();
        while (it.next()) |entry| try map.entry(entry.key_ptr.*, entry.value_ptr.*);
        return map.end();
    }

    // Normalize everything into scalar writes or delegate to shape-specific calls
    return switch (@typeInfo(T)) {
        inline .void, .null, .bool, .int, .float => |_, t| writer.write(@field(Kind, @tagName(t)), value),
        .comptime_int => writer.write(.int, value),
        .comptime_float => writer.write(.float, value),
        .enum_literal => writer.write(.string, @tagName(value)),
        .error_set => writer.write(.string, @errorName(value)),
        .optional => if (value) |v| serialize(writer, v) else writer.write(.null, null),
        .error_union => if (value) |v| serialize(writer, v) else |e| serialize(writer, e),
        .@"enum" => serializeEnum(writer, value),
        .array => |a| serializeSlice(writer, @as([]const a.child, &value)),
        .@"struct" => |s| if (s.is_tuple) serializeTuple(writer, value) else serializeStruct(writer, value, .{}),
        .@"union" => |u| if (u.tag_type != null) serializeUnion(writer, value) else @compileError("unsupported type: " ++ @typeName(T)),
        .pointer => |p| switch (p.size) {
            .one => serialize(writer, if (@typeInfo(p.child) == .array) @as([]const std.meta.Elem(p.child), value) else value.*),
            .slice => serializeSlice(writer, value),
            else => @compileError("unsupported type: " ++ @typeName(T)),
        },
        .type, .noreturn, .undefined, .@"fn", .@"opaque", .frame, .@"anyframe", .vector => @compileError("unsupported type: " ++ @typeName(T)),
    };
}

pub fn serializeEnum(writer: anytype, value: anytype) Error!void {
    if (@typeInfo(@TypeOf(value)).@"enum".is_exhaustive) {
        return writer.write(.string, @tagName(value));
    }

    return writer.write(.int, @intFromEnum(value));
}

pub fn serializeSlice(writer: anytype, value: anytype) Error!void {
    var seq = try writer.beginSeq(value.len);
    for (value) |item| try seq.element(item);
    return seq.end();
}

pub fn serializeTuple(writer: anytype, value: anytype) Error!void {
    const fields = std.meta.fields(@TypeOf(value));
    var tuple = try writer.beginTuple(fields.len);
    inline for (0..fields.len) |i| try tuple.element(value[i]);
    return tuple.end();
}

pub const SerializeStructOptions = struct {
    omit_null: enum { never, auto, always } = .auto,
};

pub fn serializeStruct(writer: anytype, value: anytype, comptime options: SerializeStructOptions) Error!void {
    const T = @TypeOf(value);
    const fields = std.meta.fields(T);
    var st = try writer.beginStruct(T, fields.len);
    inline for (fields) |f| {
        if (!meta.isOptional(f.type) or options.omit_null == .never) {
            try st.field(f.name, @field(value, f.name));
        } else {
            if (@field(value, f.name)) |v| {
                try st.field(f.name, v);
            } else if (options.omit_null == .auto and (f.defaultValue() == null or f.defaultValue().? != null)) {
                try st.field(f.name, @field(value, f.name));
            }
        }
    }
    return st.end();
}

pub fn serializeUnion(writer: anytype, value: anytype) Error!void {
    switch (value) {
        inline else => |v, t| {
            var st = try writer.beginStruct(void, 1);
            try st.field(@tagName(t), v);
            return st.end();
        },
    }
}

pub fn serializer(cx: anytype, comptime fun: anytype) Serializer(@TypeOf(cx), fun) {
    return .{ .cx = cx };
}

pub fn Serializer(comptime Cx: type, comptime fun: anytype) type {
    return struct {
        cx: Cx,

        pub inline fn serialize(self: @This(), writer: anytype) !void {
            try fun(self.cx, writer);
        }
    };
}
