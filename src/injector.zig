const std = @import("std");

/// Type-based dependency injection context. There is a small vtable overhead
/// but other than that it should very fast because all it does is a simple
/// inline for over the fields of the context struct.
pub const Injector = struct {
    ctx: *anyopaque,
    resolver: *const fn (*anyopaque, TypeId) ?*anyopaque,

    /// Create a new injector from a context ptr.
    pub fn from(ctx: anytype) Injector {
        if (@typeInfo(@TypeOf(ctx)) != .Pointer) @compileError("Expected pointer to a context");

        return .{
            .ctx = @ptrCast(ctx),
            .resolver = &resolver(@TypeOf(ctx.*)),
        };
    }

    /// Get a dependency from the context. In case of pointer types, the
    /// resolver will look both for `T` and `*T` types.
    pub fn get(self: Injector, comptime T: type) !T {
        if (T == Injector) return self;

        if (comptime @typeInfo(T) == .Pointer) {
            if (self.resolver(self.ctx, TypeId.from(@typeInfo(T).Pointer.child))) |ptr| {
                return @ptrCast(@alignCast(ptr));
            }
        }

        const ptr = self.resolver(self.ctx, TypeId.from(T)) orelse {
            std.log.debug("Missing dependency: {s}", .{@typeName(T)});
            return error.MissingDependency;
        };

        return @as(*T, @ptrCast(@alignCast(ptr))).*;
    }

    /// Call a function with dependencies. The `extra_args` tuple is used to
    /// pass additional arguments to the function.
    pub fn call(self: Injector, comptime fun: anytype, extra_args: anytype) CallRes(@TypeOf(fun)) {
        if (@typeInfo(@TypeOf(extra_args)) != .Struct) @compileError("Expected a tuple of arguments");

        var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;
        const extra_start = args.len - extra_args.len;

        inline for (0..extra_start) |i| {
            args[i] = try self.get(@TypeOf(args[i]));
        }

        inline for (extra_start..args.len, 0..) |i, j| {
            args[i] = extra_args[j];
        }

        return @call(.auto, fun, args);
    }
};

const TypeId = struct {
    id: [*:0]const u8,

    fn from(comptime T: type) TypeId {
        return .{ .id = @typeName(T) };
    }
};

fn resolver(comptime T: type) fn (*anyopaque, TypeId) ?*anyopaque {
    const H = struct {
        fn resolve(ptr: *anyopaque, type_id: TypeId) ?*anyopaque {
            var ctx: *T = @ptrCast(@alignCast(ptr));

            inline for (std.meta.fields(T)) |f| {
                if (TypeId.from(f.type).id == type_id.id) {
                    return @ptrCast(&@field(ctx, f.name));
                }
            }

            return null;
        }
    };

    return H.resolve;
}

fn CallRes(comptime F: type) type {
    switch (@typeInfo(F)) {
        .Fn => |f| {
            const R = f.return_type orelse @compileError("Invalid function");

            return switch (@typeInfo(R)) {
                .ErrorUnion => |e| return anyerror!e.payload,
                else => anyerror!R,
            };
        },
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(F))),
    }
}
