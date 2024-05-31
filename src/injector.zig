const std = @import("std");

/// Injector serves as a custom runtime scope for retrieving dependencies.
/// It can be passed around, enabling any code to request a value or reference
/// to a given type. Additionally, it can invoke arbitrary functions and supply
/// the necessary dependencies automatically.
///
/// Injectors can be nested. If a dependency is not found, the parent context
/// is searched. If the dependency is still not found, an error is returned.
pub const Injector = struct {
    ctx: *anyopaque,
    resolver: *const fn (*anyopaque, TypeId) ?*anyopaque,
    parent: ?*const Injector = null,

    /// Create an empty injector.
    pub fn empty() Injector {
        return .{ .ctx = undefined, .resolver = &resolver(*const struct {}) };
    }

    /// Create a new injector from a context ptr.
    pub fn from(ctx: anytype) Injector {
        if (@typeInfo(@TypeOf(ctx)) != .Pointer) @compileError("Expected pointer to a context");

        return .{
            .ctx = @constCast(@ptrCast(ctx)), // resolver() casts back first, so this should be safe
            .resolver = &resolver(@TypeOf(ctx)),
        };
    }

    /// Create a new injector from a parent context and a tuple of pointers.
    pub fn fromParent(parent: *const Injector, ctx: anytype) Injector {
        var res = Injector.from(ctx);
        res.parent = parent;
        return res;
    }

    /// Get a dependency from the context.
    pub fn get(self: Injector, comptime T: type) !T {
        if (T == Injector) return self;

        switch (@typeInfo(T)) {
            .Pointer => |p| {
                if (self.find(T)) |ptr| return ptr;
                if (p.is_const) if (self.find(*p.child)) |ptr| return ptr;
            },
            else => {
                if (self.find(*T)) |ptr| return ptr.*;
                if (self.find(*const T)) |ptr| return ptr.*;
            },
        }

        if (self.parent) |parent| {
            return parent.get(T);
        }

        std.log.debug("Missing dependency: {s}", .{@typeName(T)});
        return error.MissingDependency;
    }

    fn find(self: Injector, comptime T: type) ?T {
        return if (self.resolver(self.ctx, typeId(T))) |ptr| @constCast(@ptrCast(@alignCast(ptr))) else null;
    }

    /// Call a function with dependencies. The `extra_args` tuple is used to
    /// pass additional arguments to the function.
    pub fn call(self: *const Injector, comptime fun: anytype, extra_args: anytype) CallRes(@TypeOf(fun)) {
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

const TypeId = struct { id: [*:0]const u8 };

fn typeId(comptime T: type) TypeId {
    return .{ .id = @typeName(T) };
}

fn resolver(comptime T: type) fn (*anyopaque, TypeId) ?*anyopaque {
    const H = struct {
        fn resolve(ctx: *anyopaque, type_id: TypeId) ?*anyopaque {
            var cx: T = @constCast(@ptrCast(@alignCast(ctx)));

            inline for (std.meta.fields(@typeInfo(T).Pointer.child)) |f| {
                const ptr = if (comptime @typeInfo(f.type) == .Pointer) @field(cx, f.name) else &@field(cx, f.name);

                if (typeId(@TypeOf(ptr)).id == type_id.id) {
                    return @constCast(@ptrCast(ptr));
                }
            }

            if (typeId(T).id == type_id.id) {
                return ctx;
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
