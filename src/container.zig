const std = @import("std");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;
const Ref = @import("injector.zig").Ref;

pub const Container = struct {
    allocator: std.mem.Allocator,
    refs: std.ArrayListUnmanaged(Ref),
    injector: Injector,

    pub fn init(allocator: std.mem.Allocator, comptime mods: []const type) !*Container {
        const self = try allocator.create(Container);
        errdefer self.deinit();

        self.* = .{
            .allocator = allocator,
            .refs = .empty,
            .injector = .empty,
        };

        try self.register(self);
        try self.register(&self.allocator);

        if (comptime mods.len > 0) {
            try Bundle.compile(mods).init(self);
        }

        return self;
    }

    pub fn deinit(self: *Container) void {
        // TODO: cleanup
        self.refs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn register(self: *Container, ptr: anytype) !void {
        try self.refs.append(self.allocator, .from(ptr));
        self.injector = .init(self.refs.items, self.injector.parent);
    }
};

/// Comptime-resolved strategy for initializing multiple modules together.
const Bundle = struct {
    mods: []const type,
    ops: []const Op,

    fn init(self: Bundle, ct: *Container) !void {
        const inst = try ct.allocator.create(std.meta.Tuple(self.mods));
        errdefer ct.allocator.destroy(inst);

        inline for (self.ops) |op| {
            const target = &@field(inst[op.mid], op.field.name);
            try ct.register(if (comptime meta.isOnePtr(op.field.type)) target.* else target);

            switch (op.how) {
                .default => target.* = op.field.defaultValue().?,
                .auto => {
                    if (comptime !meta.isStruct(op.field.type)) @compileError(op.path() ++ ": Only plain structs can be auto-initialized");

                    inline for (std.meta.fields(op.field.type)) |f| {
                        if (f.defaultValue()) |def| {
                            @field(target, f.name) = ct.injector.find(f.type) orelse def;
                        } else {
                            @field(target, f.name) = try ct.injector.get(f.type);
                        }
                    }
                },
                .initializer => |cb| try ct.injector.call(@field(cb[0], cb[1]), .{}),
                .factory => |cb| target.* = try ct.injector.call(@field(cb[0], cb[1]), .{}),
            }
        }
    }

    fn compile(comptime mods: []const type) Bundle {
        var len: usize = 0;
        for (mods) |M| len += std.meta.fields(M).len;
        var ops: [len]Op = undefined;

        collect(&ops, mods);
        connect(&ops);
        reorder(&ops);
        const copy = ops;

        return .{
            .mods = mods,
            .ops = &copy,
        };
    }

    fn collect(ops: []Op, comptime mods: []const type) void {
        var i: usize = 0;
        for (mods, 0..) |M, mid| {
            for (std.meta.fields(M)) |f| {
                var op: Op = .{
                    .id = i,
                    .mid = mid,
                    .mod = M,
                    .field = f,
                    .how = .auto, // If nothing below works, auto-wire all the fields or fail
                };

                // Default takes precedence over any initXxx() that appear LATER in the chain.
                if (f.default_value_ptr != null) {
                    // However, it can still be overridden by an initXxx() that appears EARLIER in the chain.
                    if (findInitializer(mods[0..mid], f.type)) |meth| {
                        op.how = .useMethod(meth);
                    } else {
                        op.how = .default;
                    }
                } else {
                    // Look for any initXxx() in order (the first one wins)
                if (findInitializer(mods, f.type)) |meth| {
                    op.how = .useMethod(meth);
                    }
                    // Otherwise, try T.init() or keep it as .auto
                    else if (std.meta.hasMethod(f.type, "init")) {
                    op.how = .useMethod(.{ meta.Deref(f.type), "init" });
                    }
                }

                ops[i] = op;
                i += 1;
            }
        }
    }

    fn findInitializer(mods: []const type, comptime T: type) ?Cb {
        for (mods) |M| {
            for (std.meta.declarations(M)) |d| {
                if (d.name.len > 4 and std.mem.startsWith(u8, d.name, "init")) {
                    switch (@typeInfo(@TypeOf(@field(M, d.name)))) {
                        .@"fn" => |f| {
                            if (meta.Result(@field(M, d.name)) == T or (f.params.len > 0 and f.params[0].type.? == *T)) {
                                return .{ M, d.name };
                            }
                        },
                        else => {},
                    }
                }
            }
        } else return null;
    }

    fn connect(ops: []Op) void {
        for (ops) |*op| {
            switch (op.how) {
                .default => {},
                .auto => {
                    for (std.meta.fields(op.field.type)) |f| {
                        if (f.default_value_ptr == null) {
                            markDep(ops, op, f.type);
                        }
                    }
                },
                inline .initializer, .factory => |cb, tag| {
                    const params = @typeInfo(@TypeOf(@field(cb[0], cb[1]))).@"fn".params;

                    for (params[@intFromBool(tag == .initializer)..]) |p| {
                        markDep(ops, op, p.type.?);
                    }
                },
            }
        }
    }

    fn markDep(ops: []Op, target: *Op, comptime T: type) void {
        // Builtin
        if (T == *Container or T == Injector or T == std.mem.Allocator) return;

        for (ops) |op| {
            if (meta.Deref(op.field.type) == meta.Deref(T)) {
                target.deps |= 1 << op.id;
                return;
            }
        } else @compileError("Unknown dependency: " ++ @typeName(T) ++ "\n> " ++ target.desc());
    }

    fn reorder(ops: []Op) void {
        var i: usize = 0;
        var ready: u64 = 0;

        while (i < ops.len) {
            for (ops[i..]) |*t| {
                if ((t.deps & ready) == t.deps) {
                    ready |= 1 << t.id;
                    std.mem.swap(Op, t, &ops[i]);
                    i += 1;
                    break;
                }
            } else {
                // TODO: Consider DAG + stack because then we could also say where the cycle is
                var dump: []const u8 = "";
                for (ops[i..]) |op| dump = dump ++ op.desc() ++ "\n";

                @compileError("Cycle or missing dep:\n" ++ dump);
            }
        }
    }
};

/// Each Op represents a single service that needs to be initialized
/// and specifies how that initialization should happen.
const Op = struct {
    id: usize, // original index
    mid: usize, // module index
    mod: type,
    field: std.builtin.Type.StructField,
    deps: u64 = 0,
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
        return @typeName(self.mod) ++ "." ++ self.field.name;
    }

    fn desc(self: Op) []const u8 {
        return self.path() ++ " <- " ++ switch (self.how) {
            inline .initializer, .factory => |cb, t| @typeName(cb[0]) ++ "." ++ cb[1] ++ "() [" ++ @tagName(t) ++ "]",
            inline else => |_, t| @tagName(t),
        };
    }
};

/// Callback definition for initializer and factory methods
const Cb = struct { type, []const u8 };

test {
    const S1 = struct {};
    const S2 = struct { dep: *S1 };
    const S3 = struct { dep: *S2 };
    const S4 = struct { dep: *S3 };
    const App = struct {
        s4: S4,
        s3: S3,
        s2: S2,
        s1: S1,
    };

    const b = comptime Bundle.compile(&.{App});
    inline for (b.ops, 0..) |op, i| {
        std.debug.print("{} {s} \n", .{ i, op.path() });
    }
}

test "empty" {
    const ct = try Container.init(std.testing.allocator, &.{});
    defer ct.deinit();

    try std.testing.expectEqual(ct, ct.injector.find(*Container));
}

test "DIY container" {
    const Svc = struct { x: u32 };
    var inst: Svc = .{ .x = 123 };

    const ct = try Container.init(std.testing.allocator, &.{});
    defer ct.deinit();

    try ct.register(&inst);
    try std.testing.expectEqual(&inst, ct.injector.find(*Svc));
    try std.testing.expectEqual(123, ct.injector.find(*Svc).?.x);
}

test "basic single-mod" {
    const S1 = struct { x: u32 = 123 };
    const S2 = struct { dep: *S1 };
    const App = struct { s1: S1, s2: S2 };

    const ct = try Container.init(std.testing.allocator, &.{App});
    defer ct.deinit();

    const s1 = try ct.injector.get(*S1);
    const s2 = try ct.injector.get(*S2);

    try std.testing.expectEqual(s1, s2.dep);
    try std.testing.expectEqual(123, s2.dep.x);
}

test "basic multi-mod" {
    const S1 = struct { x: u32 = 123 };
    const S2 = struct { dep: *S1 };
    const M1 = struct { s1: S1 };
    const M2 = struct { s2: S2 };

    const ct = try Container.init(std.testing.allocator, &.{ M1, M2 });
    defer ct.deinit();

    const s1 = try ct.injector.get(*S1);
    const s2 = try ct.injector.get(*S2);

    try std.testing.expectEqual(s1, s2.dep);
    try std.testing.expectEqual(123, s2.dep.x);
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

    const ct = try Container.init(std.testing.allocator, &.{App});
    defer ct.deinit();

    const s1 = try ct.injector.get(*S1);
    const s2 = try ct.injector.get(*S2);

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

    const ct = try Container.init(std.testing.allocator, &.{App});
    defer ct.deinit();

    const s1 = try ct.injector.get(*S1);
    const s2 = try ct.injector.get(*S2);

    try std.testing.expectEqual(123, s1.x);
    try std.testing.expectEqual(456, s2.y);
}
