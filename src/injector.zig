const std = @import("std");

/// Hierarchical, stack-based dependency injection context implemented as a
/// fixed-size array of (TypeId, *anyopaque) pairs.
///
/// The stack structure is well-suited for middleware-based applications, as it
/// allows for easy addition and removal of dependencies whenever the scope
/// starts or ends.
///
/// When a dependency is requested, the context is searched from top to bottom.
/// If the dependency is not found, the parent context is searched. If the
/// dependency is still not found, an error is returned.
pub const Injector = struct {
    registry: std.BoundedArray(struct { TypeId, *anyopaque }, 32) = .{},
    parent: ?*const Injector = null,

    /// Create a new injector from a tuple of pointers.
    pub fn from(refs: anytype) !Injector {
        const T = @TypeOf(refs);

        comptime if (@typeInfo(T) != .Struct or !@typeInfo(T).Struct.is_tuple) {
            @compileError("Expected tuple of pointers");
        };

        var res = Injector{};

        inline for (std.meta.fields(T)) |f| {
            try res.push(@field(refs, f.name));
        }

        return res;
    }

    /// Create a new injector from a parent context and a tuple of pointers.
    pub fn fromParent(parent: *const Injector, refs: anytype) !Injector {
        var res = try Injector.from(refs);
        res.parent = parent;
        return res;
    }

    /// Add a dependency to the context.
    pub fn push(self: *Injector, ref: anytype) !void {
        const T = @TypeOf(ref);

        comptime if (@typeInfo(T) != .Pointer) {
            @compileError("Expected a pointer");
        };

        // This should be safe because we always check TypeId first.
        try self.registry.append(.{ TypeId.from(T), @constCast(ref) });
    }

    /// Remove the last dependency from the context.
    pub fn pop(self: *Injector) void {
        _ = self.registry.pop();
    }

    /// Get a dependency from the context.
    pub fn get(self: *const Injector, comptime T: type) !T {
        if (comptime T == *const Injector) return self;

        if (comptime @typeInfo(T) != .Pointer) {
            return (try self.get(*const T)).*;
        }

        for (self.registry.constSlice()) |node| {
            if (TypeId.from(T).id == node[0].id) {
                return @ptrCast(@alignCast(node[1]));
            }
        }

        if (self.parent) |parent| {
            return parent.get(T);
        } else {
            std.log.debug("Missing dependency: {s}", .{@typeName(T)});
            return error.MissingDependency;
        }
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

    // TODO: This is a hack which allows embedding ServerOptions in the
    //       configuration file but maybe there's a better way...
    pub fn jsonParse(_: std.mem.Allocator, _: anytype, _: std.json.ParseOptions) !Injector {
        return .{};
    }
};

const TypeId = struct {
    id: [*:0]const u8,

    fn from(comptime T: type) TypeId {
        return .{ .id = @typeName(T) };
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
