const std = @import("std");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;
const log = std.log.scoped(.tokamak);

/// While the `Injector` can be freely used with any previously created struct
/// or tuple, the `Module(T)` is more like an abstract recipe, describing how
/// the context should be created and wired together.
///
/// The way it works is that you define a struct, e.g., called `App`, where each
/// field represents a dependency that will be available for injection, and
/// also for initialization of any other services. These services will be
/// eagerly initialized unless they were previously provided, or defined with
/// a default value.
pub fn Module(comptime T: type) type {
    return struct {
        pub fn init(target: *T, parent: ?*const Injector) !Injector {
            const injector = Injector.init(target, parent orelse &.empty);

            // NOTE: The similarity with the `initService()` is rather
            //       accidental, we don't call the `T.init()`, we only inject
            //       from the outer-scope, and if that fails, we attempt to
            //       initialize the service. Also, we initialize any defaults
            //       first, so that we can use them in any of the custom
            //       initializers.

            inline for (std.meta.fields(T)) |f| {
                if (comptime @as(?*align(1) const f.type, @ptrCast(f.default_value_ptr))) |ptr| {
                    @field(target, f.name) = ptr.*;
                }
            }

            inline for (std.meta.fields(T)) |f| {
                errdefer log.debug("Failed to init " ++ @typeName(f.type), .{});

                if (injector.parent.?.find(f.type)) |dep| {
                    @field(target, f.name) = dep;
                } else if (injector.parent.?.find(Initializer(f.type))) |custom| {
                    try custom.init(&@field(target, f.name), injector);
                } else if (comptime f.default_value_ptr == null) {
                    try initService(f.type, &@field(target, f.name), injector);
                }
            }

            return injector;
        }

        fn initService(comptime S: type, target: *S, injector: Injector) !void {
            if (comptime std.meta.hasMethod(S, "init")) {
                const fac = meta.Deref(S).init;

                if (comptime !meta.isGeneric(fac) and meta.Result(fac) == S) {
                    target.* = try injector.call(fac, .{});
                    return;
                }
            }

            if (comptime @typeInfo(S) != .@"struct") {
                return error.CannotAutoInit;
            }

            inline for (std.meta.fields(S)) |f| {
                if (comptime @as(?*align(1) const f.type, @ptrCast(f.default_value_ptr))) |def| {
                    @field(target, f.name) = injector.find(f.type) orelse def.*;
                } else {
                    @field(target, f.name) = try injector.get(f.type);
                }
            }
        }

        pub fn deinit(injector: Injector) void {
            const target = injector.find(*T).?;
            const fields = std.meta.fields(T);

            inline for (0..fields.len) |i| {
                const f = fields[fields.len - i - 1];

                if (injector.parent.?.find(f.type) == null) {
                    if (comptime std.meta.hasMethod(f.type, "deinit")) {
                        @field(target, f.name).deinit();
                    }
                }
            }
        }
    };
}

pub fn Initializer(comptime T: type) type {
    return struct {
        // check: *const fn (target: *T, injector: Injector) bool,
        init: *const fn (target: *T, injector: Injector) anyerror!void,
    };
}

pub fn initializer(comptime T: type, comptime fun: anytype) Initializer(T) {
    const H = struct {
        fn init(_: *T, injector: Injector) anyerror!void {
            try injector.call(fun, .{});
        }
    };

    return .{
        .init = &H.init,
    };
}

pub fn factory(comptime fun: anytype) Initializer(meta.Result(fun)) {
    const H = struct {
        fn init(target: *meta.Result(fun), injector: Injector) anyerror!void {
            target.* = try injector.call(fun, .{});
        }
    };

    return .{
        .init = &H.init,
    };
}
