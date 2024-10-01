const std = @import("std");
const Injector = @import("injector.zig").Injector;

pub fn Factory(comptime T: type) type {
    return struct {
        call: *const fn (injector: Injector) anyerror!T,

        /// Use user-provided function to create an instance.
        pub fn use(comptime fun: anytype) @This() {
            return factory(struct {
                fn impl(injector: Injector) anyerror!T {
                    return injector.call(fun, .{});
                }
            });
        }

        /// Use T.init() to create an instance.
        pub const init: @This() = factory(struct {
            fn impl(injector: Injector) anyerror!T {
                const S = if (@typeInfo(T) == .pointer) std.meta.Child(T) else T;
                return injector.call(S.init, .{});
            }
        });

        pub const auto: @This() = factory(struct {
            fn impl(injector: Injector) anyerror!T {
                if (comptime std.meta.hasMethod(T, "init")) {
                    return init.call(injector);
                }

                var res: T = undefined;

                // Init fields with default values.
                inline for (std.meta.fields(T)) |f| {
                    if (comptime @as(?*align(1) const f.type, @ptrCast(f.default_value))) |ptr| {
                        @field(res, f.name) = ptr.*;
                    }
                }

                inline for (std.meta.fields(T)) |f| {
                    if (comptime f.default_value == null) {
                        if (injector.find(f.type)) |dep| {
                            @field(res, f.name) = dep;
                        } else if (injector.find(Factory(f.type))) |fac| {
                            // TODO: This will work but the order can be wrong. Can we detect this in comptime?
                            @field(res, f.name) = try fac.call(.init(&res, &injector));
                        } else {
                            std.log.debug("Missing dependency: {s}", .{@typeName(f.type)});
                            return error.MissingDependency;
                        }
                    }
                }

                return res;
            }
        });

        fn factory(comptime H: type) @This() {
            return .{ .call = &H.impl };
        }
    };
}
