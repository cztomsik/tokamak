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

    pub const EMPTY: Injector = .{ .ctx = undefined, .resolver = empty };

    /// Create a new injector from a context ptr and an optional parent.
    pub fn init(ctx: anytype, parent: ?*const Injector) Injector {
        if (comptime @typeInfo(@TypeOf(ctx)) != .Pointer) {
            @compileError("Expected pointer to a context, got " ++ @typeName(@TypeOf(ctx)));
        }

        const H = struct {
            fn resolve(ptr: *anyopaque, tid: TypeId) ?*anyopaque {
                var cx: @TypeOf(ctx) = @constCast(@ptrCast(@alignCast(ptr)));
                const res: Resolver = .{ .tid = tid };

                // TODO: find a better name?
                if (comptime @hasDecl(@TypeOf(cx.*), "resolve")) {
                    return cx.resolve(res);
                }

                return res.visit(cx);
            }
        };

        return .{
            .ctx = @constCast(@ptrCast(ctx)), // resolver() casts back first, so this should be safe
            .resolver = &H.resolve,
            .parent = parent,
        };
    }

    pub fn find(self: Injector, comptime T: type) ?T {
        if (comptime T == Injector) {
            return self;
        }

        if (comptime @sizeOf(T) == 0) {
            return undefined;
        }

        if (comptime @typeInfo(T) != .Pointer) {
            return if (self.find(*const T)) |p| p.* else null;
        }

        if (self.resolver(self.ctx, TypeId.get(T))) |ptr| {
            return @ptrCast(@constCast(@alignCast(ptr)));
        }

        if (comptime @typeInfo(T).Pointer.is_const) {
            if (self.resolver(self.ctx, TypeId.get(*@typeInfo(T).Pointer.child))) |ptr| {
                return @ptrCast(@constCast(@alignCast(ptr)));
            }
        }

        return if (self.parent) |p| p.find(T) else null;
    }

    /// Get a dependency from the context.
    pub fn get(self: Injector, comptime T: type) !T {
        return self.find(T) orelse {
            std.log.debug("Missing dependency: {s}", .{@typeName(T)});
            return error.MissingDependency;
        };
    }

    /// Attempt to create a struct using dependencies from the context.
    pub fn create(self: Injector, comptime T: type) !T {
        var res: T = undefined;

        inline for (@typeInfo(T).Struct.fields) |f| {
            @field(res, f.name) = try self.get(f.type);
        }

        return res;
    }

    /// Call a function with dependencies. The `extra_args` tuple is used to
    /// pass additional arguments to the function.
    pub fn call(self: Injector, comptime fun: anytype, extra_args: anytype) CallRes(@TypeOf(fun)) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .Struct) {
            @compileError("Expected a tuple of arguments");
        }

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

pub const TypeId = enum(usize) {
    _,

    pub inline fn get(comptime T: type) TypeId {
        return @enumFromInt(@intFromPtr(@typeName(T)));
    }
};

const Resolver = struct {
    tid: TypeId,

    pub fn visit(self: Resolver, cx: anytype) ?*anyopaque {
        inline for (std.meta.fields(@TypeOf(cx.*))) |f| {
            const ptr = if (comptime @typeInfo(f.type) == .Pointer) @field(cx, f.name) else &@field(cx, f.name);
            std.debug.assert(@intFromPtr(ptr) != 0xaaaaaaaaaaaaaaaa);

            if (self.tid == TypeId.get(@TypeOf(ptr))) {
                return @ptrCast(@constCast(ptr));
            }
        }

        if (self.tid == TypeId.get(@TypeOf(cx))) {
            return @ptrCast(@constCast(cx));
        }

        return null;
    }
};

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

fn empty(_: *anyopaque, _: TypeId) ?*anyopaque {
    return null;
}

const t = std.testing;

test Injector {
    var num: u32 = 123;
    var cx = .{ .num = &num };
    const inj = Injector.init(&cx, null);

    try t.expectEqual(inj, inj.get(Injector));
    try t.expectEqual(&num, inj.get(*u32));
    try t.expectEqual(@as(*const u32, &num), inj.get(*const u32));
    try t.expectEqual(123, inj.get(u32));
    try t.expectEqual(error.MissingDependency, inj.get(u64));
}
