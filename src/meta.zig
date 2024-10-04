const std = @import("std");

pub const TypeId = enum(usize) {
    _,

    pub inline fn get(comptime T: type) TypeId {
        return @enumFromInt(@intFromPtr(@typeName(T)));
    }
};

pub fn ReturnType(comptime fun: anytype) type {
    return switch (@typeInfo(@TypeOf(fun))) {
        .@"fn" => |f| f.return_type.?,
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(fun))),
    };
}

pub fn Result(comptime fun: anytype) type {
    const R = ReturnType(fun);

    return switch (@typeInfo(R)) {
        .error_union => |r| r.payload,
        else => R,
    };
}

pub fn isGeneric(comptime fun: anytype) bool {
    return @typeInfo(@TypeOf(fun)).@"fn".is_generic;
}

pub fn isOnePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .One,
        else => false,
    };
}

pub fn Deref(comptime T: type) type {
    return if (isOnePtr(T)) std.meta.Child(T) else T;
}
