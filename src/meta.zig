const std = @import("std");

// https://github.com/ziglang/zig/issues/19858#issuecomment-2370673253
pub const TypeId = *const struct {
    _: u8 = undefined,
};

pub inline fn tid(comptime T: type) TypeId {
    const H = struct {
        comptime {
            _ = T;
        }
        var id: Deref(TypeId) = .{};
    };
    return &H.id;
}

pub fn dupe(allocator: std.mem.Allocator, value: anytype) !@TypeOf(value) {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => try dupe(allocator, value orelse return null),
        .@"struct" => |s| {
            var res: @TypeOf(value) = undefined;
            inline for (s.fields) |f| @field(res, f.name) = try dupe(allocator, @field(value, f.name));
            return res;
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) allocator.dupe(p.child, value) else error.NotSupported,
            else => value,
        },
        else => value,
    };
}

pub fn Return(comptime fun: anytype) type {
    return switch (@typeInfo(@TypeOf(fun))) {
        .@"fn" => |f| f.return_type.?,
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(fun))),
    };
}

pub fn Result(comptime fun: anytype) type {
    const R = Return(fun);

    return switch (@typeInfo(R)) {
        .error_union => |r| r.payload,
        else => R,
    };
}

pub fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

pub fn isGeneric(comptime fun: anytype) bool {
    return @typeInfo(@TypeOf(fun)).@"fn".is_generic;
}

pub fn isOnePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one,
        else => false,
    };
}

pub fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child == u8 or switch (@typeInfo(ptr.child)) {
            .array => |arr| arr.child == u8,
            else => false,
        },
        else => false,
    };
}

pub fn Deref(comptime T: type) type {
    return if (isOnePtr(T)) std.meta.Child(T) else T;
}

pub fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

pub fn fieldTypes(comptime T: type) []const type {
    return comptime blk: {
        const fields = std.meta.fields(T);
        var types: [fields.len]type = undefined;
        for (&types, fields) |*t, f| t.* = f.type;
        const copy = types;
        break :blk &copy;
    };
}
