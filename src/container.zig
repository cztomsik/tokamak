const std = @import("std");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;
const Ref = @import("injector.zig").Ref;
const Buf = @import("util.zig").Buf;

pub const Container = struct {
    allocator: std.mem.Allocator,
    injector: Injector,
    refs: std.ArrayListUnmanaged(Ref),
    deinit_fns: std.ArrayListUnmanaged(*const fn (*Container) void),

    pub fn init(allocator: std.mem.Allocator, comptime mods: []const type) !*Container {
        const self = try allocator.create(Container);
        errdefer self.deinit();

        self.* = .{
            .allocator = allocator,
            .injector = .empty,
            .refs = .empty,
            .deinit_fns = .empty,
        };

        try self.register(self);
        try self.register(&self.allocator);

        if (comptime mods.len > 0) {
            try Bundle.compile(mods).init(self);
        }

        return self;
    }

    pub fn deinit(self: *Container) void {
        const fns = self.deinit_fns.items;
        for (1..fns.len + 1) |i| fns[fns.len - i](self);
        self.deinit_fns.deinit(self.allocator);

        self.refs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn register(self: *Container, ptr: anytype) !void {
        try self.refs.append(self.allocator, .ref(ptr));
        self.injector = .init(self.refs.items, self.injector.parent);
    }

    pub fn registerDeinit(self: *Container, comptime fun: anytype) !void {
        comptime std.debug.assert(meta.Return(fun) == void);

        const H = struct {
            fn deinit(ct: *Container) void {
                ct.injector.call(fun, .{}) catch unreachable;
            }
        };

        try self.deinit_fns.append(self.allocator, &H.deinit);
    }
};

/// Comptime-assisted strategy for initializing multiple modules together.
const Bundle = struct {
    mods: []const type,
    ops: []const Op,
    ext: []const meta.TypeId,

    fn init(self: Bundle, ct: *Container) !void {
        const bundle = try ct.allocator.create(std.meta.Tuple(self.mods));
        errdefer {
            // TODO: ct.deinitUpTo(prev_deinit_count)
            ct.allocator.destroy(bundle);
        }

        const H = struct {
            fn deinit(ct2: *Container, bundle2: *std.meta.Tuple(self.mods)) void {
                ct2.allocator.destroy(bundle2);
            }
        };
        try ct.register(bundle);
        try ct.registerDeinit(H.deinit);

        var done: u64 = 0; // Eagerly-initialized module fields
        var ready: u64 = 0; // All the deps we might need
        var ticks: usize = 0;

        while (@popCount(done) < self.ops.len) : (ticks += 1) {
            inline for (self.ops) |op| {
                if (done & (1 << op.id) == 0 and op.deps & ready == op.deps) {
                    try op.init(ct, bundle);

                    if (comptime std.meta.hasMethod(op.field.type, "deinit")) {
                        try ct.registerDeinit(meta.Deref(op.field.type).deinit);
                    }

                    done |= 1 << op.id;
                    ready |= done;

                    if (ct.refs.items.len > @popCount(ready)) {
                        for (ct.refs.items[ct.refs.items.len - (ct.refs.items.len - @popCount(ready)) ..]) |ref| {
                            if (std.mem.indexOfScalar(meta.TypeId, self.ext, ref.tid)) |j| {
                                ready |= @as(u64, 1) << @as(u6, @intCast((self.ops.len + j)));
                            }
                        }
                    }
                }
            }

            if (ticks > 2 * self.ops.len) {
                std.log.debug("-- Ext deps:", .{});
                inline for (self.ext, 0..) |tid, i| {
                    const x: u8 = if ((ready >> self.ops.len) & (1 << i) != 0) 'x' else ' ';
                    std.log.debug("[{c}] {s}", .{ x, tid.name });
                }

                std.log.debug("-- Pending tasks:", .{});
                inline for (self.ops, 0..) |op, i| {
                    const x: u8 = if (done & (1 << i) != 0) 'x' else ' ';
                    std.log.debug("[{c}] {s}", .{ x, comptime op.desc() });
                }

                // NOTE: Cycles should still be detected in comptime
                @panic("Init failed (missing ext)");
            }
        }

        // Register all the modules too
        inline for (self.mods, 0..) |M, mid| {
            if (comptime @sizeOf(M) > 0) {
                try ct.register(&bundle[mid]);
            } else {
                try ct.register(@as(*M, @ptrFromInt(0xaaaaaaaaaaaaaaaa)));
            }
        }

        // Every module can define init/deinit hooks
        inline for (self.mods) |M| {
            if (std.meta.hasFn(M, "afterBundleInit")) {
                try ct.injector.call(M.afterBundleInit, .{});
            }

            if (std.meta.hasFn(M, "beforeBundleDeinit")) {
                try ct.registerDeinit(M.beforeBundleDeinit);
            }
        }
    }

    fn compile(comptime mods: []const type) Bundle {
        var ops: Buf(Op) = .initComptime(64);
        var ext: Buf(meta.TypeId) = .initComptime(64);

        collect(&ops, mods);
        markDeps(ops.items(), &ext);
        reorder(ops.items());

        return .{
            .mods = mods,
            .ops = ops.finish(),
            .ext = ext.finish(),
        };
    }

    fn collect(ops: *Buf(Op), comptime mods: []const type) void {
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

                ops.push(op);
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
                            if (meta.Result(@field(M, d.name)) == T or (meta.Result(@field(M, d.name)) == void and f.params.len > 0 and f.params[0].type.? == *T)) {
                                return .{ M, d.name };
                            }
                        },
                        else => {},
                    }
                }
            }
        } else return null;
    }

    fn markDeps(ops: []Op, exts: *Buf(meta.TypeId)) void {
        @setEvalBranchQuota(100 * ops.len);

        for (ops) |*op| {
            switch (op.how) {
                .default => {},
                .auto => {
                    for (std.meta.fields(op.field.type)) |f| {
                        if (f.default_value_ptr == null) {
                            markDep(ops, exts, op, f.type);
                        }
                    }
                },
                inline .initializer, .factory => |cb, tag| {
                    const params = @typeInfo(@TypeOf(@field(cb[0], cb[1]))).@"fn".params;

                    for (params[@intFromBool(tag == .initializer)..]) |p| {
                        markDep(ops, exts, op, p.type orelse continue);
                    }
                },
            }
        }
    }

    fn markDep(ops: []Op, exts: *Buf(meta.TypeId), target: *Op, comptime T: type) void {
        // Builtins
        if (T == *Container or T == *Injector or T == std.mem.Allocator) return;

        for (ops) |op| {
            if (meta.Deref(op.field.type) == meta.Deref(T)) {
                target.deps |= 1 << op.id;
                return;
            }
        } else {
            if (@typeInfo(T) != .optional) {
                target.deps |= 1 << (ops.len + exts.len);
                exts.push(meta.tid(meta.Deref(T)));
            }
        }
    }

    fn reorder(ops: []Op) void {
        var i: usize = 0;
        var ready: u64 = (~@as(u64, 0)) << ops.len; // Ops are pending but everything else is "ready"

        while (i < ops.len) {
            for (ops[i..]) |*t| {
                if ((t.deps & ready) == t.deps) {
                    ready |= 1 << t.id;
                    std.mem.swap(Op, t, &ops[i]);
                    i += 1;
                    break;
                }
            } else {
                var dump: []const u8 = "";
                for (ops[i..]) |op| dump = dump ++ op.desc() ++ "\n";

                @compileError("Cycle detected:\n" ++ dump);
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

    fn init(self: Op, ct: *Container, bundle: anytype) !void {
        const target: *self.field.type = if (comptime @sizeOf(self.field.type) > 0) &@field(bundle[self.mid], self.field.name) else @ptrFromInt(0xaaaaaaaaaaaaaaaa);
        try ct.register(if (comptime meta.isOnePtr(self.field.type)) target.* else target);

        switch (self.how) {
            .default => target.* = self.field.defaultValue().?,
            .auto => {
                if (comptime !meta.isStruct(self.field.type)) @compileError(self.path() ++ ": Only plain structs can be auto-initialized");

                inline for (std.meta.fields(self.field.type)) |f| {
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

    // This should @compileError:
    // const Invalid = struct {
    //     const A = struct { b: *B };
    //     const B = struct { a: *A };
    //     a: A,
    //     b: B,
    // };
    // _ = comptime Bundle.compile(&.{Invalid});
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

    const app = try ct.injector.get(*App);
    try std.testing.expectEqual(&app.s1, app.s2.dep);
    try std.testing.expectEqual(123, app.s2.dep.x);

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

test "M.initXxx() precedence" {
    const S1 = struct { x: u32 };
    const S2 = struct { y: u32 };
    const S3 = struct { z: u32 };

    const App = struct {
        s1: S1,
        s2: S2,
        s3: S3,

        pub fn initS1() S1 {
            unreachable;
        }

        pub fn initS2(_: *S2) void {
            unreachable;
        }
    };

    const Fallbacks = struct {
        pub fn initS1() S1 {
            unreachable;
        }

        pub fn initS2(_: *S2) void {
            unreachable;
        }

        pub fn initS3(s3: *S3) void {
            s3.z = 789;
        }
    };

    const Mocks = struct {
        pub fn initS1() S1 {
            return .{ .x = 123 };
        }

        pub fn initS2(s2: *S2) void {
            s2.y = 456;
        }
    };

    const ct = try Container.init(std.testing.allocator, &.{ Mocks, App, Fallbacks });
    defer ct.deinit();

    const s1 = try ct.injector.get(*S1);
    const s2 = try ct.injector.get(*S2);
    const s3 = try ct.injector.get(*S3);

    try std.testing.expectEqual(123, s1.x);
    try std.testing.expectEqual(456, s2.y);
    try std.testing.expectEqual(789, s3.z);
}
