const std = @import("std");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;
const log = std.log.scoped(.tokamak);

pub fn Module(comptime T: type) type {
    return struct {
        inner: ?T = null,
        injector: Injector = .empty,
        provided: Injector = .empty,

        pub fn with(cx: anytype) @This() {
            return .{
                .provided = Injector.init(cx, null),
            };
        }

        pub fn init(self: *@This()) !void {
            self.inner = undefined;
            errdefer self.inner = null;

            const target = &self.inner.?;
            const injector = Injector.init(target, &self.provided);

            // NOTE: This is similar to the initService() function, but we
            //       only inject from the outer scope, and if that fails, we
            //       always try to auto-initialize the field, whereas the other
            //       will fail if a dependency is missing. Lastly, we initialize
            //       defaults first, so that we can use them in the custom
            //       initializers.

            inline for (std.meta.fields(T)) |f| {
                if (comptime @as(?*align(1) const f.type, @ptrCast(f.default_value))) |ptr| {
                    @field(target, f.name) = ptr.*;
                }
            }

            inline for (std.meta.fields(T)) |f| {
                errdefer log.debug("Failed to init " ++ @typeName(f.type), .{});

                if (self.provided.find(f.type)) |dep| {
                    @field(target, f.name) = dep;
                } else if (self.provided.find(Initializer(f.type))) |custom| {
                    try custom.init(&@field(target, f.name), injector);
                } else if (comptime f.default_value == null) {
                    try initService(f.type, &@field(target, f.name), injector);
                }
            }

            self.injector = injector;
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
                if (comptime @as(?*align(1) const f.type, @ptrCast(f.default_value))) |def| {
                    @field(target, f.name) = injector.find(f.type) orelse def.*;
                } else {
                    @field(target, f.name) = try injector.get(f.type);
                }
            }
        }

        pub fn deinit(self: *@This()) void {
            if (self.inner) |*inner| {
                const fields = std.meta.fields(T);

                inline for (0..fields.len) |i| {
                    const f = fields[fields.len - i - 1];

                    if (self.provided.find(f.type) == null) {
                        if (comptime std.meta.hasMethod(f.type, "deinit")) {
                            @field(inner, f.name).deinit();
                        }
                    }
                }

                self.inner = null;
                self.injector = .empty;
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
