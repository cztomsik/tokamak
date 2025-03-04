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
pub const Module = struct {
    type: type,

    pub fn forType(comptime M: type) Module {
        return .{
            .type = M,
        };
    }

    pub fn initAlone(ctx: anytype, injector: ?*const Injector) !Injector {
        comptime std.debug.assert(meta.isOnePtr(@TypeOf(ctx)) and !meta.isTuple(@TypeOf(ctx.*)));

        return Plan.forTypes(&.{@TypeOf(ctx.*)}).init(@as(*[1]@TypeOf(ctx.*), ctx), injector);
    }

    pub fn initTogether(ctx: anytype, injector: ?*const Injector) !Injector {
        comptime std.debug.assert(meta.isOnePtr(@TypeOf(ctx)) and meta.isTuple(@TypeOf(ctx.*)));

        return Plan.forTypes(meta.fieldTypes(@TypeOf(ctx.*))).init(ctx, injector);
    }

    pub fn deinit(ctx: anytype) void {
        comptime std.debug.assert(meta.isOnePtr(@TypeOf(ctx)));

        if (comptime meta.isTuple(@TypeOf(ctx.*))) {
            Plan.forTypes(meta.fieldTypes(@TypeOf(ctx.*))).deinit(ctx);
        } else {
            Plan.forTypes(&.{@TypeOf(ctx.*)}).deinit(@as(*[1]@TypeOf(ctx.*), ctx));
        }
    }

    fn findInitializer(self: Module, comptime T: type) ?Plan.Cb {
        for (std.meta.declarations(self.type)) |d| {
            if (d.name.len > 4 and std.mem.startsWith(u8, d.name, "init")) {
                switch (@typeInfo(@TypeOf(@field(self.type, d.name)))) {
                    .@"fn" => |f| {
                        if (meta.Result(@field(self.type, d.name)) == T or (f.params.len > 0 and f.params[0].type.? == *T)) {
                            return .{ self.type, d.name };
                        }
                    },
                    else => {},
                }
            }
        } else return null;
    }
};

const Plan = struct {
    mods: []const Module,
    ops: []const Op,

    const Cb = struct { type, []const u8 };

    const Op = struct {
        m: usize,
        mod: Module,
        field: std.builtin.Type.StructField,
        how: union(enum) {
            default,
            auto,
            initializer: Cb,
            factory: Cb,
        },

        fn path(self: Op) []const u8 {
            return @typeName(self.mod.type) ++ "." ++ self.field.name;
        }

        fn desc(self: Op) []const u8 {
            return switch (self.how) {
                inline .initializer, .factory => |cb, t| @typeName(cb[0]) ++ "." ++ cb[1] ++ "() [" ++ @tagName(t) ++ "]",
                inline else => |_, t| @tagName(t),
            };
        }
    };

    fn forTypes(types: []const type) Plan {
        var mods: [types.len]Module = undefined;
        for (types, 0..) |M, i| mods[i] = Module.forType(M);
        const copy = mods;
        return compile(&copy);
    }

    fn compile(mods: []const Module) Plan {
        var n: usize = 0;
        for (mods) |m| n += std.meta.fields(m.type).len;
        var ops: [n]Op = undefined;
        var i: usize = 0;
        for (mods, 0..) |mod, m| {
            for (std.meta.fields(mod.type)) |f| {
                var op: Op = .{ .m = m, .mod = mod, .field = f, .how = .auto };

                if (mod.findInitializer(meta.Deref(f.type))) |cb| {
                    op.how = if (meta.Result(@field(cb[0], cb[1])) == void) .{ .initializer = cb } else .{ .factory = cb };
                } else if (f.defaultValue() != null) {
                    op.how = .default;
                } else if (std.meta.hasMethod(f.type, "init")) {
                    const cb: Cb = .{ meta.Deref(f.type), "init" };
                    op.how = if (meta.Result(cb[0].init) == void) .{ .initializer = cb } else .{ .factory = cb };
                }

                ops[i] = op;
                i += 1;
            }
        }

        // TODO: resolve providers & set to .call where applicable

        // TODO: resolve overrides

        // TODO: validate

        // TODO: reorder (DAG)

        const copy = ops;

        return .{
            .mods = mods,
            .ops = &copy,
        };
    }

    fn init(self: Plan, ctx: anytype, parent: ?*const Injector) !Injector {
        // TODO: maybe we should change Injector too
        const H = struct {
            fn resolve(cx: @TypeOf(ctx), tid: meta.TypeId) ?*anyopaque {
                inline for (0..self.mods.len) |m| {
                    if (comptime @sizeOf(self.mods[m].type) > 0) {
                        if (Injector.init(&cx[m], null).resolver(&cx[m], tid)) |p| {
                            return p;
                        }
                    }
                } else return null;
            }
        };

        const injector: Injector = .{
            .ctx = @ptrCast(ctx), // TODO: require cx to be ptr AND indexable, the tuple will not work this way
            .resolver = @ptrCast(&H.resolve),
            .parent = parent,
        };

        inline for (self.ops) |op| {
            log.debug("{s} <- {s}", .{ op.path(), op.desc() });

            const target = &@field(ctx[op.m], op.field.name);

            switch (op.how) {
                .default => target.* = op.field.defaultValue().?,
                .auto => {
                    if (comptime !meta.isStruct(op.field.type)) @compileError(op.path() ++ ": Only plain structs can be auto-initialized");

                    inline for (std.meta.fields(op.field.type)) |f| {
                        if (f.defaultValue()) |def| {
                            @field(target, f.name) = injector.find(f.type) orelse def;
                        } else {
                            @field(target, f.name) = try injector.get(f.type);
                        }
                    }
                },
                .initializer => |cb| try injector.call(@field(cb[0], cb[1]), .{}),
                .factory => |cb| target.* = try injector.call(@field(cb[0], cb[1]), .{}),
            }
        }

        return injector;
    }

    fn deinit(self: Plan, ctx: anytype) void {
        inline for (0..self.ops.len) |i| {
            const op = self.ops[self.ops.len - i - 1];

            switch (op.how) {
                .auto => {},
                else => {
                    if (comptime std.meta.hasMethod(op.field.type, "deinit")) {
                        log.debug("{s}.deinit()", .{op.path()});

                        @field(ctx[op.m], op.field.name).deinit();
                    }
                },
            }
        }
    }
};

test "basic" {
    const S1 = struct { x: u32 = 123 };
    const S2 = struct { dep: *S1 };
    const App = struct { s1: S1, s2: S2 };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    const s1 = try inj.get(*S1);
    const s2 = try inj.get(*S2);

    try std.testing.expectEqual(s1, s2.dep);
    try std.testing.expectEqual(123, s2.dep.x);
}

test "T.init() factory" {
    const Svc = struct {
        x: u32,

        pub fn init() @This() {
            return .{ .x = 123 };
        }
    };
    const App = struct { svc: Svc };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    const svc = try inj.get(*Svc);
    try std.testing.expectEqual(123, svc.x);
}

test "T.init() initializer" {
    const Svc = struct {
        x: u32,

        pub fn init(self: *@This()) void {
            self.x = 123;
        }
    };
    const App = struct { svc: Svc };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    const svc = try inj.get(*Svc);
    try std.testing.expectEqual(123, svc.x);
}

test "M.initXxx() factory" {
    const Svc = struct { x: u32 };
    const App = struct {
        svc: Svc,

        pub fn initSvc() Svc {
            return .{ .x = 123 };
        }
    };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    const svc = try inj.get(*Svc);
    try std.testing.expectEqual(123, svc.x);
}

test "M.initXxx() initializer" {
    const Svc = struct { x: u32 };
    const App = struct {
        svc: Svc,

        pub fn initSvc(svc: *Svc) void {
            svc.x = 123;
        }
    };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    const svc = try inj.get(*Svc);
    try std.testing.expectEqual(123, svc.x);
}

test "multimod" {
    const S1 = struct { x: u32 = 123 };
    const S2 = struct { dep: *S1 };
    const M1 = struct { s1: S1 };
    const M2 = struct { s2: S2 };

    var cx: struct { M1, M2 } = undefined;
    const inj = try Module.initTogether(&cx, null);
    defer Module.deinit(&cx);

    const s1 = try inj.get(*S1);
    const s2 = try inj.get(*S2);

    try std.testing.expectEqual(s1, s2.dep);
    try std.testing.expectEqual(123, s2.dep.x);
}
