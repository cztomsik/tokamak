const std = @import("std");

/// Type-based dependency injection context. There is a small vtable overhead
/// but other than that it should be very fast because all it does is a simple
/// inline for over the fields of the context struct.
pub const Injector = struct {
    ctx: *anyopaque,
    resolver: *const fn (*anyopaque, TypeId) ?*anyopaque,

    /// Create empty injector.
    pub fn empty() Injector {
        return .{ .ctx = undefined, .resolver = &resolver(struct {}) };
    }

    /// Create a new injector from a context ptr.
    pub fn from(ctx: anytype) Injector {
        if (@typeInfo(@TypeOf(ctx)) != .Pointer) @compileError("Expected pointer to a context");

        return .{
            .ctx = @ptrCast(ctx),
            .resolver = &resolver(@TypeOf(ctx.*)),
        };
    }

    /// Create a new injector from a pointer to a tuple of injectors.
    pub fn multi(injectors: anytype) Injector {
        if (@typeInfo(@TypeOf(injectors)) != .Pointer) @compileError("Expected pointer to a tuple of injectors");

        return .{
            // note we never modify the tuple, so it's safe to cast away const
            .ctx = @constCast(@ptrCast(injectors)),
            .resolver = &multiResolver(@TypeOf(injectors.*)),
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

// /// A set of dependencies to be created and destroyed together.
// /// Dependencies are created in the order they are defined, using both the
// /// parent injector and the context itself. The deinit methods are called in
// /// reverse order.
// pub fn Scope(comptime factories: anytype) type {
//     const T = comptime brk: {
//         var types: [factories.len]type = undefined;

//         for (factories, 0..) |f, i| {
//             types[i] = @typeInfo(CallRes(f)).payload;
//         }

//         break :brk std.meta.Tuple(&types);
//     };

//     return struct {
//         instances: T,

//         /// Initialize the context by calling the factories.
//         pub fn init(self: *T, parent: Injector) void {
//             const inj = Injector.multi(.{ self.injector(), parent });

//             inline for (std.meta.fields(T), 0..) |f, i| {
//                 @field(self, f.name) = try inj.call(factories[i], .{});
//             }
//         }

//         /// Deinitialize the context by calling the deinit methods (if any).
//         pub fn deinit(self: *@This()) void {
//             const fields = std.meta.fields(T);

//             inline for (0..fields.len) |i| {
//                 const f = fields[fields.len - i - 1];
//                 if (@hasDecl(f.type, "deinit")) {
//                     @field(self.instances, f.name).deinit();
//                 }
//             }
//         }

//         /// Create a new injector from the context.
//         pub fn injector(self: *@This()) Injector {
//             return Injector.from(self.instances);
//         }
//     };
// }

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

fn multiResolver(comptime T: type) fn (*anyopaque, TypeId) ?*anyopaque {
    const H = struct {
        fn resolve(ptr: *anyopaque, type_id: TypeId) ?*anyopaque {
            const ctx: *T = @ptrCast(@alignCast(ptr));

            inline for (ctx) |injector| {
                if (injector.resolver(injector.ctx, type_id)) |p| return p;
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
