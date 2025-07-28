const std = @import("std");
const util = @import("util.zig");

// https://github.com/ziglang/zig/issues/19858#issuecomment-2370673253
// NOTE: I've tried to make it work with enum / packed struct but I was still
//       getting weird "operation is runtime due to this operand" here and there
//       but it should be possible because we do something similar in util.Smol
pub const TypeId = *const struct {
    name: [*:0]const u8,

    pub fn sname(self: *const @This()) []const u8 {
        // NOTE: we can't switch (invalid record Zig 0.14.1)
        if (self == tid([]const u8)) return "str";
        if (self == tid(?[]const u8)) return "?str";
        return shortName(std.mem.span(self.name), '.');
    }
};

pub inline fn tid(comptime T: type) TypeId {
    const H = struct {
        const id: Deref(TypeId) = .{ .name = @typeName(T) };
    };
    return &H.id;
}

pub fn tids(comptime types: []const type) []const TypeId {
    var buf = util.Buf(TypeId).initComptime(types.len);
    for (types) |T| buf.push(tid(T));
    return buf.finish();
}

/// Ptr to a comptime value, wrapped together with its type. We use this to
/// pass around values (including a concrete fun types!) during the Bundle
/// compilation.
pub const ComptimeVal = struct {
    type: type,
    ptr: *const anyopaque,

    pub fn wrap(comptime val: anytype) ComptimeVal {
        return .{ .type = @TypeOf(val), .ptr = @ptrCast(&val) };
    }

    pub fn unwrap(self: ComptimeVal) self.type {
        return @as(*const self.type, @ptrCast(@alignCast(self.ptr))).*;
    }
};

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

pub fn free(allocator: std.mem.Allocator, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| free(allocator, v),
        .@"struct" => |s| {
            inline for (s.fields) |f| free(allocator, @field(value, f.name));
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) allocator.free(value),
            else => {},
        },
        else => {},
    }
}

pub fn upcast(context: anytype, comptime T: type) T {
    return .{
        .context = context,
        .vtable = comptime brk: {
            const Impl = Deref(@TypeOf(context));
            var vtable: T.VTable = undefined;
            for (std.meta.fields(T.VTable)) |f| {
                @field(vtable, f.name) = @ptrCast(&@field(Impl, f.name));
            }

            const copy = vtable;
            break :brk &copy;
        },
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

pub fn LastArg(comptime fun: anytype) type {
    const params = @typeInfo(@TypeOf(fun)).@"fn".params;
    return params[params.len - 1].type.?;
}

pub inline fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

pub inline fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

pub inline fn isGeneric(comptime fun: anytype) bool {
    return @typeInfo(@TypeOf(fun)).@"fn".is_generic;
}

pub inline fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

pub inline fn isOnePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one,
        else => false,
    };
}

pub inline fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice,
        else => false,
    };
}

pub inline fn isString(comptime T: type) bool {
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

pub fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

pub inline fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

pub fn fieldTypes(comptime T: type) []const type {
    const fields = std.meta.fields(T);
    var buf = util.Buf(type).initComptime(fields.len);
    for (fields) |f| buf.push(f.type);
    return buf.finish();
}

pub fn fnParams(comptime fun: anytype) []const type {
    const info = @typeInfo(@TypeOf(fun));
    if (info != .@"fn") @compileError("Expected a function, got " ++ @typeName(@TypeOf(fun)));

    const params = info.@"fn".params;
    var buf = util.Buf(type).initComptime(params.len);
    for (params) |param| buf.push(param.type.?);
    return buf.finish();
}

// TODO: move somewhere else?
fn shortName(name: []const u8, delim: u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, delim)) |i| name[i + 1 ..] else name;
}
