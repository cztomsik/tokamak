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
};

/// Compiled plan represents the initialization and deinitialization strategy
/// for a set of modules.
const Plan = struct {
    mods: []const Module,
    ops: []const Op,

    /// Callback definition for initializer and factory methods
    const Cb = struct { type, []const u8 };

    /// Each Op represents a single service that needs to be initialized
    /// and specifies how that initialization should happen.
    const Op = struct {
        m: usize,
        mod: Module,
        field: std.builtin.Type.StructField,
        how: union(enum) {
            default,
            auto,
            initializer: Cb,
            factory: Cb,

            fn useMethod(meth: Cb) @This() {
                return if (meta.Result(@field(meth[0], meth[1])) == void) .{ .initializer = meth } else .{ .factory = meth };
            }
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
        for (types, 0..) |M, i| mods[i] = .{ .type = M };
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

                if (findOverride(mods, f.type)) |meth| {
                    op.how = .useMethod(meth);
                } else if (findInitializer(mod, f.type)) |meth| {
                    op.how = .useMethod(meth);
                } else if (f.defaultValue() != null) {
                    op.how = .default;
                } else if (findProvider(mods, f.type)) |meth| {
                    op.how = .useMethod(meth);
                } else if (std.meta.hasMethod(f.type, "init")) {
                    op.how = .useMethod(.{ meta.Deref(f.type), "init" });
                }

                ops[i] = op;
                i += 1;
            }
        }

        // Push dependent ops further down
        // TODO: find a better way
        var changed = true;
        while (changed) {
            changed = false;
            for (0..ops.len - 1) |j| {
                const op = ops[j];
                const next = ops[j + 1];

                const swap = switch (op.how) {
                    .initializer, .factory => |cb| blk: {
                        // Check for dependency on next field's type
                        const params = @typeInfo(@TypeOf(@field(cb[0], cb[1]))).@"fn".params;
                        for (params) |param| {
                            const param_type = param.type orelse continue;
                            if (param_type == next.field.type or
                                (meta.isOnePtr(param_type) and meta.Deref(param_type) == next.field.type))
                            {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    },
                    else => false,
                };

                if (swap) {
                    std.mem.swap(Op, &ops[j], &ops[j + 1]);
                    changed = true;
                }
            }
        }

        const copy = ops;

        return .{
            .mods = mods,
            .ops = &copy,
        };
    }

    fn findInitializer(mod: Module, comptime T: type) ?Cb {
        return findMethodWithPrefix(&.{mod}, "init", T);
    }

    fn findProvider(mods: []const Module, comptime T: type) ?Cb {
        return findMethodWithPrefix(mods, "provide", T);
    }

    fn findOverride(mods: []const Module, comptime T: type) ?Cb {
        return findMethodWithPrefix(mods, "override", T);
    }

    fn findMethodWithPrefix(mods: []const Module, comptime prefix: []const u8, comptime T: type) ?Cb {
        for (mods) |mod| {
            for (std.meta.declarations(mod.type)) |d| {
                if (d.name.len > prefix.len and std.mem.startsWith(u8, d.name, prefix)) {
                    switch (@typeInfo(@TypeOf(@field(mod.type, d.name)))) {
                        .@"fn" => |f| {
                            if (meta.Result(@field(mod.type, d.name)) == T or (f.params.len > 0 and f.params[0].type.? == *T)) {
                                return .{ mod.type, d.name };
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        return null;
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

test "reordering" {
    const App = struct {
        first: u32,
        nums: []const u32 = &.{ 1, 2, 3 },

        pub fn initFirst(nums: []const u32) u32 {
            return nums[0]; // This should segfault without re-order
        }
    };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    try std.testing.expectEqual(1, inj.get(u32));
}

test "T.init()" {
    const S1 = struct {
        x: u32,

        pub fn init() @This() {
            return .{ .x = 123 };
        }
    };

    const S2 = struct {
        y: u32,

        pub fn init(self: *@This()) void {
            self.y = 456;
        }
    };

    const App = struct { s1: S1, s2: S2 };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    const s1 = try inj.get(*S1);
    const s2 = try inj.get(*S2);

    try std.testing.expectEqual(123, s1.x);
    try std.testing.expectEqual(456, s2.y);
}

test "M.initXxx()" {
    const S1 = struct { x: u32 };
    const S2 = struct { y: u32 };
    const App = struct {
        s1: S1,
        s2: S2,

        pub fn initS1() S1 {
            return .{ .x = 123 };
        }

        pub fn initS2(s2: *S2) void {
            s2.y = 456;
        }
    };

    var app: App = undefined;
    const inj = try Module.initAlone(&app, null);
    defer Module.deinit(&app);

    const s1 = try inj.get(*S1);
    const s2 = try inj.get(*S2);

    try std.testing.expectEqual(123, s1.x);
    try std.testing.expectEqual(456, s2.y);
}

test "basic multimod" {
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

test "M.provideXxx()" {
    const S1 = struct { x: u32 };
    const S2 = struct { y: u32 };

    const M1 = struct { s1: S1, s2: S2 };
    const M2 = struct {
        pub fn provideS1() S1 {
            return .{ .x = 123 };
        }

        pub fn provideS2(s2: *S2) void {
            s2.y = 456;
        }
    };

    var cx: struct { M1, M2 } = undefined;
    const inj = try Module.initTogether(&cx, null);
    defer Module.deinit(&cx);

    const s1 = try inj.get(*S1);
    const s2 = try inj.get(*S2);

    try std.testing.expectEqual(123, s1.x);
    try std.testing.expectEqual(456, s2.y);
}

test "M.overrideXxx()" {
    const S1 = struct { x: u32 };
    const S2 = struct { y: u32 };

    const M1 = struct {
        s1: S1,
        s2: S2,

        pub fn initS1() S1 {
            unreachable;
        }

        pub fn initS2(_: *S2) void {
            unreachable;
        }
    };

    const M2 = struct {
        pub fn provideS1() S1 {
            unreachable;
        }
    };

    const M3 = struct {
        pub fn overrideS1() S1 {
            return .{ .x = 123 };
        }

        pub fn overrideS2(s2: *S2) void {
            s2.y = 456;
        }
    };

    var cx: struct { M1, M2, M3 } = undefined;
    const inj = try Module.initTogether(&cx, null);
    defer Module.deinit(&cx);

    const s1 = try inj.get(*S1);
    const s2 = try inj.get(*S2);

    try std.testing.expectEqual(123, s1.x);
    try std.testing.expectEqual(456, s2.y);
}
