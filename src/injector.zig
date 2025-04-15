const std = @import("std");
const meta = @import("meta.zig");
const t = std.testing;

pub const Ref = struct {
    tid: meta.TypeId,
    ptr: *anyopaque,
    is_const: bool,

    pub fn from(ptr: anytype) Ref {
        return .{
            .tid = meta.tid(@TypeOf(ptr.*)),
            .ptr = @ptrCast(@constCast(@alignCast(ptr))),
            .is_const = @typeInfo(@TypeOf(ptr)).pointer.is_const,
        };
    }
};

/// Injector serves as a custom runtime scope for retrieving dependencies.
/// It can be passed around, enabling any code to request a value or reference
/// to a given type. Additionally, it can invoke arbitrary functions and supply
/// the necessary dependencies automatically.
///
/// Injectors can be nested. If a dependency is not found, the parent context
/// is searched. If the dependency is still not found, an error is returned.
pub const Injector = struct {
    refs: []const Ref = &.{},
    parent: ?*const Injector = null,

    pub const empty: Injector = .{};

    pub fn init(refs: []const Ref, parent: ?*const Injector) Injector {
        return .{
            .refs = refs,
            .parent = parent,
        };
    }

    pub fn find(self: Injector, comptime T: type) ?T {
        if (comptime T == Injector) {
            return self;
        }

        if (comptime !meta.isOnePtr(T)) {
            return if (self.find(*const T)) |p| p.* else null;
        }

        for (self.refs) |r| {
            if (r.tid == meta.tid(meta.Deref(T)) and (!r.is_const or @typeInfo(T).pointer.is_const)) {
                return @ptrCast(@constCast(@alignCast(r.ptr)));
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

    test get {
        var num: u32 = 123;
        const inj = Injector.init(&.{.from(&num)}, null);

        try t.expectEqual(inj, inj.get(Injector));
        try t.expectEqual(&num, inj.get(*u32));
        try t.expectEqual(@as(*const u32, &num), inj.get(*const u32));
        try t.expectEqual(123, inj.get(u32));
        try t.expectEqual(error.MissingDependency, inj.get(u64));
    }

    /// Call a function with dependencies. The `extra_args` tuple is used to
    /// pass additional arguments to the function. Function with anytype can
    /// be called as long as the concrete value is provided in the `extra_args`.
    pub fn call(self: Injector, comptime fun: anytype, extra_args: anytype) anyerror!meta.Result(fun) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .@"struct") {
            @compileError("Expected a tuple of arguments");
        }

        const params = @typeInfo(@TypeOf(fun)).@"fn".params;
        const extra_start = params.len - extra_args.len;

        const types = comptime brk: {
            var types: [params.len]type = undefined;
            for (0..extra_start) |i| types[i] = params[i].type orelse @compileError("reached anytype");
            for (extra_start..params.len, 0..) |i, j| types[i] = @TypeOf(extra_args[j]);
            break :brk &types;
        };

        var args: std.meta.Tuple(types) = undefined;
        inline for (0..args.len) |i| args[i] = if (i < extra_start) try self.get(@TypeOf(args[i])) else extra_args[i - extra_start];

        return @call(.auto, fun, args);
    }
};

fn resolveNull(_: *anyopaque, _: meta.TypeId) ?*anyopaque {
    return null;
}
