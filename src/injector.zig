const builtin = @import("builtin");
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

    pub const EMPTY: Injector = .{ .ctx = undefined, .resolver = &resolver(*struct {}) };
    pub threadlocal var current = EMPTY;

    /// Create a new injector from a context ptr and an optional parent.
    pub fn init(ctx: anytype, parent: ?*const Injector) Injector {
        if (comptime @typeInfo(@TypeOf(ctx)) != .Pointer) {
            @compileError("Expected pointer to a context");
        }

        return .{
            .ctx = @constCast(@ptrCast(ctx)), // resolver() casts back first, so this should be safe
            .resolver = &resolver(@TypeOf(ctx)),
            .parent = parent,
        };
    }

    /// Get a dependency from the context.
    pub fn get(self: Injector, comptime T: type) !T {
        if (comptime T == Injector) {
            return self;
        }

        if (comptime @sizeOf(T) == 0) {
            return undefined;
        }

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

    /// Attempt to create a struct using dependencies from the context.
    pub fn create(self: Injector, comptime T: type) !T {
        var res: T = undefined;

        inline for (@typeInfo(T).Struct.fields) |f| {
            @field(res, f.name) = try self.get(f.type);
        }

        return res;
    }

    fn find(self: Injector, comptime P: type) ?P {
        const ptr = self.resolver(self.ctx, typeId(P));

        if (comptime builtin.mode == .Debug) {
            if (@intFromPtr(ptr) == 0xaaaaaaaaaaaaaaaa and @sizeOf(@typeInfo(P).Pointer.child) > 0) {
                std.debug.panic("bad ptr: {s}", .{@typeName(P)});
            }
        }

        return @ptrFromInt(@intFromPtr(ptr));
    }

    /// Call a function with dependencies. The `extra_args` tuple is used to
    /// pass additional arguments to the function.
    pub fn call(self: Injector, comptime fun: anytype, extra_args: anytype) CallRes(@TypeOf(fun)) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .Struct) {
            @compileError("Expected a tuple of arguments");
        }

        const prev = current;
        defer current = prev;
        current = self;

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

/// Wrapper ZST helper for getting a dependency from the inner-most injector.
/// This will only work inside `injector.call()` and it will panic if the
/// dependency is not found, so it should be used with caution. It is useful
/// for getting request-scoped dependencies, but notably, it can also be used
/// for dependency inversion.
pub fn Scoped(comptime T: type) type {
    return struct {
        pub fn get(_: @This()) T {
            return Injector.current.get(T) catch |err| {
                std.debug.panic("Scoped<{s}>: {s}", .{ @typeName(T), @errorName(err) });
            };
        }
    };
}

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
