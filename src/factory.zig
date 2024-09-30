const std = @import("std");
const Injector = @import("injector.zig").Injector;

pub fn Factory(comptime T: type) type {
    return struct {
        call: *const fn (injector: Injector) anyerror!T,

        /// Use user-provided function to create an instance.
        pub fn use(comptime fun: anytype) @This() {
            return .{
                .call = (struct {
                    fn impl(injector: Injector) anyerror!T {
                        return injector.call(fun, .{});
                    }
                }).impl,
            };
        }

        /// Use T.init() to create an instance.
        pub const init = .{
            .call = (struct {
                fn impl(injector: Injector) anyerror!T {
                    const S = switch (@typeInfo(T)) {
                        .pointer => |p| p.child,
                        else => T,
                    };
                    return injector.call(S.init, .{});
                }
            }).impl,
        };

        pub const auto = .{
            .call = (struct {
                fn impl(injector: Injector) anyerror!T {
                    if (comptime std.meta.hasMethod(T, "init")) {
                        return init.call(injector);
                    }

                    var res: T = undefined;

                    inline for (std.meta.fields(T)) |f| {
                        if (injector.find(f.type)) |dep| {
                            @field(res, f.name) = dep;
                        } else {
                            if (comptime @as(?*align(1) const f.type, @ptrCast(f.default_value))) |ptr| {
                                @field(res, f.name) = ptr.*;
                            } else {
                                std.log.debug("Missing dependency: {s}", .{@typeName(T)});
                                return error.MissingDependency;
                            }
                        }
                    }

                    return res;
                }
            }).impl,
        };
    };
}
