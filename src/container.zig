// # Container v2
//
// - [x] remove "runtime-peeling", `Container.init()` is fully-resolved & prepared in comptime now
// - [x] get rid of all `initXxx()`, `before/afterXxx` magic methods
// - [x] introduce one `M.configure(*tk.Bundle)` which can be used for everything (called in **comptime**)
// - [x] check that deps are unique, make mods mostly order-independent (except mock/override)
// - [x] introduce init/deinit runtime hooks (in **addition to** providers)
// - [x] decide if we want fallback/lazy (we don't)
// - [x] interfaces (intrusive)
// - [x] split to several meaningful commits (meta, impl, examples, readme, ...)
// - [x] include this list in the PR description & merge it
// - [x] remove comptime hooks; honor `T.provider`

const builtin = @import("builtin");
const std = @import("std");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;
const Ref = @import("injector.zig").Ref;
const Buf = @import("util.zig").Buf;

pub const Container = struct {
    allocator: std.mem.Allocator,
    injector: Injector,
    bundle: *anyopaque,
    deinit_fn: *const fn (*Container) void,

    /// Creates a new container from the given modules.
    ///
    /// At comptime, this builds the dependency graph, resolves initialization
    /// order, and generates a specialized struct. At runtime, it allocates
    /// the container and initializes all dependencies in the computed order.
    pub fn init(allocator: std.mem.Allocator, comptime mods: []const type) !*Container {
        // TODO: maybe we can now avoid this alloc?
        const self = try allocator.create(Container);
        errdefer allocator.destroy(self);

        const b = try allocator.create(Bundle.compile(mods));
        errdefer allocator.destroy(b);

        self.* = .{
            .allocator = allocator,
            .injector = .empty,
            .bundle = undefined,
            .deinit_fn = undefined,
        };

        try b.init(self);
        self.bundle = @ptrCast(b);
        self.deinit_fn = struct {
            fn deinit(ct: *Container) void {
                const allocator2 = ct.allocator;
                const b2: @TypeOf(b) = @ptrCast(@alignCast(ct.bundle));
                b2.deinit(ct);
                allocator2.destroy(b2);
                allocator2.destroy(ct);
            }
        }.deinit;

        return self;
    }

    /// Destroy the container and all its dependencies (in reverse order).
    pub fn deinit(self: *Container) void {
        self.deinit_fn(self);
    }
};

/// Specifies how a dependency should be initialized.
///
/// Used with `Bundle.provide()`, `Bundle.override()`, and `Bundle.mock()` to
/// control dependency initialization.
pub const How = union(enum) {
    /// If there is `T.init()`, it will be used either as a factory or as an
    /// initializer; otherwise, if the type is a struct, its fields will be
    /// filled using `injector.get(f.type)`. In other cases, a compile error
    /// will be raised.
    auto,

    /// Explicitly use `T.init()` function.
    ///
    /// Supports both factory style (`fn() T`) and initializer style (`fn(*T) void`).
    /// Compile error if the type has no `init()` function.
    init,

    /// Initialize by injecting all struct fields.
    ///
    /// Each field is resolved using `inj.get(f.type)`. Fields with default values
    /// use the default if the dependency is not found.
    autowire,

    // internal
    val: meta.ComptimeVal, // *const T
    fac: meta.ComptimeVal, // fn(...deps) !T
    fun: meta.ComptimeVal, // fn(ptr: *T, ...deps) !void
    fref: struct { type, []const u8 }, // &T.field

    /// This dependency should be initialized using the provided comptime value.
    ///
    /// NOTE: If the dep type is a mutable ptr, then you can still pass a ref to
    ///       a global var this way. Not recommended, but good to know.
    pub fn value(val: anytype) How {
        return .{ .val = .wrap(val) };
    }

    /// Initialize the dependency using `ptr.* = try inj.call(fun)`.
    /// The function will be called at the proper time, but if you cause a cycle
    /// you may still get a compile error.
    ///
    /// Cycles should be avoided, but you can always define an empty initializer
    /// for one of them, or use `.value(undefined)`. The former is better
    /// because you can still control the order by declaring the deps.
    pub fn factory(fac: anytype) How {
        return .{ .fac = .wrap(fac) };
    }

    /// Initialize the dependency using `try inj.call(fun)`.
    /// Like with factory, if you get into a cycle, you can either adapt the
    /// other end, or in the worst case, force `undefined`.
    pub fn initializer(init: anytype) How {
        return .{ .fun = .wrap(init) };
    }

    /// Initialize the dependency by calling a given function. The function can
    /// be fallible and it can return either its dep type or void. Either way,
    /// the dependency is considered to be initialized after this call.
    pub fn call(fun: anytype) How {
        return if (meta.Result(fun) == void) .initializer(fun) else .factory(fun);
    }
};

const DepId = enum(u8) { empty = 255, _ };
const DepMask = u256;

const Dep = struct {
    id: DepId = .empty,
    type: type,
    provider: How,
    state: union(enum) {
        instance: struct { type: type, offset: usize },
        override,
    },
    mask: DepMask = 0, // bitset of what we need
    next: DepId = .empty, // chain for hash collisions

    fn desc(self: Dep) []const u8 {
        return @typeName(self.type) ++ " " ++ @tagName(self.provider);
    }

    fn ptr(self: Dep, data: []u8) *self.type {
        return if (@sizeOf(self.type) > 0) @ptrCast(@alignCast(&data[self.state.instance.offset])) else undefined;
    }

    fn initInstance(self: Dep, data: []u8, inj: *Injector) !void {
        const inst = self.ptr(data);

        switch (self.provider) {
            .autowire => {
                const svc = @typeInfo(self.type).@"struct";
                inline for (svc.field_names, svc.field_types, svc.field_attrs) |f, ft, fa| {
                    if (fa.defaultValue(ft)) |def| {
                        @field(inst, f) = inj.find(ft) orelse def;
                    } else {
                        @field(inst, f) = try inj.get(ft);
                    }
                }
            },
            .val => |v| inst.* = v.unwrap(),
            .fac => |f| inst.* = try inj.call(f.unwrap()),
            .fun => |f| try inj.call(f.unwrap()),
            .fref => |r| inst.* = &@field(try inj.get(*r[0]), r[1]),
            else => unreachable,
        }
    }

    fn deinitInstance(self: Dep, _: []u8, inj: *Injector) void {
        switch (self.provider) {
            .val, .fref, .autowire => return, // No-op!
            .fac, .fun => {}, // Proceed
            else => unreachable,
        }

        // TODO: not 100% sure if this is always the case
        if (std.meta.hasMethod(self.type, "deinit")) {
            inj.call(meta.Deref(self.type).deinit) catch unreachable;

            // TODO: this didn't work properly with heap-allocated services
            // (we'd need to also check if ptr is ** and then deref once)
            // TODO: if we don't do that we should probably also remove the
            // `data` arg from deinit, and maybe rethink this again?
            //
            // const deinit = meta.Deref(self.type).deinit;
            // const params = @typeInfo(@TypeOf(deinit)).@"fn".params;

            // if (params.len == 1 and meta.Deref(params[0].type.?) == meta.Deref(self.type)) {
            //     self.ptr(data).deinit();
            // } else {
            //     inj.call(deinit) catch unreachable;
            // }
        }
    }
};

// internal, always runtime
const Hook = struct {
    kind: enum { init, deinit },
    fun: meta.ComptimeVal,
    mask: DepMask = 0,

    fn desc(self: Hook) []const u8 {
        return "hook " ++ @tagName(self.kind) ++ " " ++ @typeName(self.fun.type);
    }
};

// internal
const Op = union(enum) {
    dep: Dep,
    hook: Hook,

    fn desc(self: Op) []const u8 {
        return switch (self) {
            inline else => |v, t| @tagName(t) ++ " " ++ v.desc(),
        };
    }
};

/// Compile-time dependency graph builder.
pub const Bundle = struct {
    deps: Buf(Dep),
    index: [256]DepId = @splat(.empty),
    runtime_hooks: Buf(Hook), // when the deps are ready / before they are gone
    n_inst: usize = 0,
    n_data: usize = 0,
    max_align: usize = 1,

    fn typeHash(comptime T: type) u8 {
        const name = @typeName(meta.Deref(T));
        var h: usize = 131;
        for (name) |c| h = h *% 31 +% c;
        return @truncate(h); // h % 256 == @truncate()
    }

    /// Registers all fields of module M as dependencies.
    ///
    /// For each field:
    /// - Fields with default values use `.value(default)`
    /// - Fields without defaults use `.auto`
    /// - Fields with an `interface` sub-field auto-register `&T.interface`
    ///
    /// If there's a `pub fn M.configure(*Bundle)` defined, it will be called
    /// (and it may recur). This is where you can define extra refs, register
    /// init/deinit/compile hooks or even add more dependencies conditionally
    /// and/or be more explicit about how it will be initialized.
    pub fn addModule(self: *Bundle, comptime M: type) void {
        self.provide(M, .value(undefined));
        const start = self.findDep(M).?.state.instance.offset;

        const mod = @typeInfo(M).@"struct";
        for (mod.field_names, mod.field_types, mod.field_attrs) |f, ft, fa| {
            // Add "inline" inst (without alloc)
            self.insertDep(.{
                .state = .{ .instance = .{
                    .type = ft,
                    .offset = if (fa.@"comptime") start else start + @offsetOf(M, f),
                } },
                .type = ft,
                .provider = if (fa.defaultValue(ft)) |v| .value(v) else .auto,
            });
            self.n_inst += 1;

            // Auto-add &T.interface, if present
            if (meta.isStruct(ft) and @hasField(ft, "interface")) {
                self.expose(ft, "interface");
            }
        }

        if (std.meta.hasFn(M, "configure")) {
            M.configure(self);
        }
    }

    /// Adds a single dependency with the specified initialization strategy.
    /// Use this to add dependencies that are not module fields. The dependency
    /// can still be overridden via `override()` or mocked via `mock()`, but any
    /// other re-definition will result in a compile error.
    pub fn provide(self: *Bundle, comptime T: type, how: How) void {
        self.insertDep(.{
            .state = self.allocInstance(T),
            .type = T,
            .provider = how,
        });
    }

    /// Only allowed during a test run. Use this in your test module to override
    /// how some dependency should be initialized. This should not be part of
    /// your regular modules, and calling it outside of the test runner will
    /// result in a compile error.
    pub fn mock(self: *Bundle, comptime T: type, how: How) void {
        if (!builtin.is_test) @compileError("bundle.mock() can only be used in tests");
        self.override(T, how);
    }

    /// Overrides how an existing dependency should be initialized. Works across
    /// module boundaries (last one wins). Use this sparingly, as it can make
    /// initialization order harder to follow. For post-initialization logic,
    /// prefer `addInitHook()` instead.
    pub fn override(self: *Bundle, comptime T: type, how: How) void {
        self.insertDep(.{
            .state = .override,
            .type = T,
            .provider = how,
        });
    }

    /// Adds a reference to a struct field as a separate dependency. Use this if
    /// you need to inject ptr to some sub-part of your struct.
    pub fn expose(self: *Bundle, comptime T: type, comptime field: []const u8) void {
        // TODO: would be great, if we could just write the ref, without any data overhead
        //       also, should this still be part of the regular unique/override chain?
        self.provide(*@FieldType(T, field), .{ .fref = .{ T, field } });
    }

    /// Registers a function to be called during container initialization, as
    /// soon as all its deps are ready.
    pub fn addInitHook(self: *Bundle, comptime fun: anytype) void {
        self.runtime_hooks.push(.{ .kind = .init, .fun = .wrap(fun) });
    }

    /// Registers a function to be called right before any of its deps are
    /// cleaned up. Executes in reverse order of init hooks.
    pub fn addDeinitHook(self: *Bundle, comptime fun: anytype) void {
        self.runtime_hooks.push(.{ .kind = .deinit, .fun = .wrap(fun) });
    }

    // TODO: public?
    fn compile(comptime mods: []const type) type {
        var bundle = Bundle{
            .deps = .initComptime(255),
            .runtime_hooks = .initComptime(64),
        };

        // Build the initial graph using provided modules
        for (mods) |M| {
            bundle.addModule(M);
        }

        for (bundle.deps.items()) |*dep| {
            bundle.resolveOne(dep);
        }

        for (bundle.runtime_hooks.items()) |*hook| {
            for (@typeInfo(hook.fun.type).@"fn".param_types) |P| bundle.mark(P orelse continue, &hook.mask);
        }

        return CompiledBundle(bundle.render(), bundle.n_inst, bundle.n_data, bundle.max_align);
    }

    fn resolveOne(self: *Bundle, dep: *Dep) void {
        // TODO: Reconsider this, it's likely a mistake but it's also common to have shared Mocks module with more than we need.
        // if (dep.state == .override) {
        //     @compileError("Unused override for " ++ @typeName(dep.type));
        // }

        if (dep.provider == .auto and @hasDecl(meta.Deref(dep.type), "provider")) {
            dep.provider = meta.Deref(dep.type).provider;
        }

        if (dep.provider == .auto or dep.provider == .init) {
            if (std.meta.hasFn(meta.Deref(dep.type), "init")) {
                dep.provider = .call(@field(meta.Deref(dep.type), "init"));
            } else if (dep.provider == .init) {
                @compileError("Type " ++ @typeName(dep.type) ++ " does not have an init() method");
            }
        }

        if (dep.provider == .auto) {
            dep.provider = .autowire;
        }

        if (dep.provider == .autowire) {
            if (!meta.isStruct(dep.type)) {
                @compileError("Only struct types can be autowired: " ++ @typeName(dep.type));
            }
        }

        switch (dep.provider) {
            .autowire => for (std.meta.fieldNames(dep.type), std.meta.fieldTypes(dep.type)) |f, ft| if (!std.mem.eql(u8, f, "interface")) self.mark(ft, &dep.mask),
            .val => {},
            .fac => |f| for (@typeInfo(f.type).@"fn".param_types) |P| self.mark(P orelse continue, &dep.mask),
            // NOTE: `fun` usually takes `*T` as first arg, but it's not required anymore
            .fun => |f| for (@typeInfo(f.type).@"fn".param_types[1..]) |P| if (meta.Deref(P orelse continue) != dep.type) self.mark(P.?, &dep.mask),
            .fref => |r| self.mark(r[0], &dep.mask),
            else => unreachable,
        }
    }

    fn mark(self: *Bundle, comptime T: type, mask: *DepMask) void {
        // Builtins
        if (T == *Container or T == *Injector or T == std.mem.Allocator) return;

        if (self.findDep(T)) |dep| {
            mask.* |= 1 << @intFromEnum(dep.id);
        }
    }

    fn render(self: *Bundle) []const Op {
        var buf = Buf(Op).initComptime(self.deps.len + self.runtime_hooks.len);
        var ready: DepMask = 0;
        var hooks: DepMask = 0;

        while (@popCount(ready) < self.n_inst) {
            for (self.deps.items(), 0..) |dep, i| {
                if (ready & (1 << i) == 0 and ready & dep.mask == dep.mask) {
                    buf.push(.{ .dep = dep });
                    ready |= 1 << i;
                    break;
                }
            } else {
                @compileError("Cycle found");
            }

            for (self.runtime_hooks.items(), 0..) |hook, i| {
                if (hooks & (1 << i) == 0 and ready & hook.mask == hook.mask) {
                    buf.push(.{ .hook = hook });
                    hooks |= 1 << i;
                }
            }
        }

        return buf.finish();
    }

    /// Finds an existing dependency by type. Matches by base type (T.*).
    pub fn findDep(self: *Bundle, comptime T: type) ?*Dep {
        // Whenever we look for uniqueness or for dep tracking, we want to use base types
        const expected = meta.Deref(T);
        var idx = self.index[typeHash(T)];

        while (idx != .empty) {
            const dep = &self.deps.buf[@intFromEnum(idx)];
            if (meta.Deref(dep.type) == expected) return dep;
            idx = dep.next;
        } else return null;
    }

    fn insertDep(self: *Bundle, dep: Dep) void {
        if (self.findDep(dep.type)) |existing| {
            // Check unique
            if (existing.state == .instance and dep.state == .instance) {
                @compileError("Cannot re-define " ++ @typeName(dep.type));
            }

            // Incoming .override - keep the current state, replace the provider (last one wins)
            if (dep.state == .override) {
                existing.provider = dep.provider;
                return;
            }

            // Pending override - keep the provider, replace the state
            if (existing.state == .override) {
                existing.state = dep.state;
                return;
            }

            unreachable;
        }

        // TODO: M.configure() is unbounded so this may still be too low in practice
        @setEvalBranchQuota(self.deps.len * 256);

        // New dep - prepend to chain at this hash bucket
        const h = typeHash(dep.type);

        var new_dep = dep;
        new_dep.id = @enumFromInt(@as(u8, @intCast(self.deps.len)));
        new_dep.next = self.index[h];
        self.deps.push(new_dep);
        self.index[h] = new_dep.id;
    }

    fn allocInstance(self: *Bundle, comptime T: type) @FieldType(Dep, "state") {
        const offset = std.mem.alignForward(usize, self.n_data, @alignOf(T));
        self.n_inst += 1;
        self.n_data = offset + @sizeOf(T);
        self.max_align = @max(self.max_align, @alignOf(T));
        return .{ .instance = .{ .type = T, .offset = offset } };
    }
};

fn CompiledBundle(comptime ops: []const Op, comptime n_inst: usize, comptime n_data: usize, comptime max_align: usize) type {
    return struct {
        refs: [n_inst + 2]Ref,
        data: [n_data]u8 align(max_align),

        fn init(self: *@This(), ct: *Container) !void {
            // We NEED to use ct.inj directly, because if anyone saves this ptr, it needs to stay valid (ie. not be on the stack)
            const inj = &ct.injector;

            self.pushRef(inj, ct);
            self.pushRef(inj, &ct.allocator);

            var pc: usize = 0;
            errdefer {
                std.debug.print("Failed to init: pc={}\n", .{pc});
                dump(pc);
                self.deinitBackwards(ct, pc);
            }

            inline for (ops) |op| {
                switch (op) {
                    .dep => |dep| {
                        // NOTE: this should be the only case where we need the pointer in advance
                        if (dep.provider == .fun) {
                            self.pushRef(inj, dep.ptr(&self.data));
                        }

                        try dep.initInstance(&self.data, inj);

                        // NOTE: pushRef() auto-derefs **T, and we can't save ref at the top because it is not yet initialized!
                        if (dep.provider != .fun) {
                            self.pushRef(inj, dep.ptr(&self.data));
                        }
                    },

                    .hook => |hook| {
                        if (hook.kind == .init) {
                            try inj.call(hook.fun.unwrap());
                        }
                    },
                }

                pc += 1;
            }
        }

        fn deinit(self: *@This(), ct: *Container) void {
            self.deinitBackwards(ct, ops.len);
        }

        fn deinitBackwards(self: *@This(), ct: *Container, pc: usize) void {
            inline for (0..ops.len) |i| {
                const j = ops.len - 1 - i;

                if (pc > j) {
                    switch (ops[ops.len - 1 - i]) {
                        .dep => |dep| {
                            dep.deinitInstance(&self.data, &ct.injector);
                        },

                        .hook => |hook| {
                            if (hook.kind == .deinit) {
                                // TODO: this is not 100% right (child scopes)
                                ct.injector.call(hook.fun.unwrap()) catch unreachable;
                            }
                        },
                    }
                }
            }
        }

        fn pushRef(self: *@This(), inj: *Injector, ptr: anytype) void {
            // std.debug.print("push ref {} {s}\n", .{ inj.refs.len, @typeName(@TypeOf(ptr)) });
            self.refs[inj.refs.len] = .ref(if (meta.isOnePtr(@TypeOf(ptr.*))) ptr.* else ptr);
            inj.refs = self.refs[0 .. inj.refs.len + 1];
        }

        fn dump(pc: usize) void {
            inline for (ops, 0..) |op, i| {
                std.debug.print("{c} {s}\n", .{
                    @as(u8, if (pc > i) 'x' else if (pc == i) '>' else ' '),
                    comptime op.desc(),
                });
            }
        }
    };
}

test "empty" {
    const ct = try Container.init(std.testing.allocator, &.{});
    defer ct.deinit();

    try std.testing.expectEqual(2, ct.injector.refs.len);
    try std.testing.expectEqual(ct, ct.injector.find(*Container));
}

test "basic single-mod" {
    const S1 = struct { x: u32 = 123 };
    const S2 = struct { dep: *S1 };
    const App = struct { s1: S1, s2: S2 };

    const ct = try Container.init(std.testing.allocator, &.{App});
    defer ct.deinit();

    try std.testing.expectEqual(5, ct.injector.refs.len);

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

    try std.testing.expectEqual(6, ct.injector.refs.len);

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

    try std.testing.expectEqual(5, ct.injector.refs.len);

    const s1 = try ct.injector.get(*S1);
    const s2 = try ct.injector.get(*S2);

    try std.testing.expectEqual(123, s1.x);
    try std.testing.expectEqual(456, s2.y);
}

test "M.configure()" {
    const S1 = struct { x: u32 };
    const S2 = struct { dep: *S1 };

    const App = struct {
        s2: S2,

        var hook_ok: bool = false;

        pub fn configure(bundle: *Bundle) void {
            bundle.provide(S1, .auto);
            bundle.provide(u32, .value(123));
            bundle.addInitHook(check);
        }

        fn check(s2: *S2) void {
            if (s2.dep.x == 123) {
                hook_ok = true;
            }
        }
    };

    const ct = try Container.init(std.testing.allocator, &.{App});
    defer ct.deinit();

    try std.testing.expectEqual(6, ct.injector.refs.len);
    try std.testing.expect(App.hook_ok);

    const s2 = try ct.injector.get(*S2);
    try std.testing.expectEqual(123, s2.dep.x);
}

test "partial deinit" {
    const H = struct {
        fn Alloc(comptime T: type) type {
            return struct {
                ptr: *T,

                pub fn init(allocator: std.mem.Allocator) !@This() {
                    return .{ .ptr = try allocator.create(T) };
                }

                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    allocator.destroy(self.ptr);
                }
            };
        }
    };

    const Fail = struct {
        pub fn init(_: *std.array_list.Managed(u8), _: *std.array_list.Managed(i8)) !@This() {
            return error.SomethingWentWrong;
        }

        pub fn deinit(_: *@This()) void {
            unreachable;
        }
    };

    const App = struct {
        dep1: H.Alloc(u8),
        dep2: H.Alloc(i8),
        fail: Fail,
    };

    _ = Container.init(std.testing.allocator, &.{App}) catch {};
}

test "heap-allocated svc (ct2 regression)" {
    const Svc = struct {
        gpa: std.mem.Allocator,
        x: u32,

        var deinit_called: bool = false;

        pub fn init(allocator: std.mem.Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{
                .gpa = allocator,
                .x = 123,
            };
            return self;
        }

        pub fn deinit(self: *@This()) void {
            deinit_called = true;
            const allocator = self.gpa;
            allocator.destroy(self);
        }
    };

    const App = struct {
        service: *Svc,
    };

    const ct = try Container.init(std.testing.allocator, &.{App});
    const svc = try ct.injector.get(*Svc);

    try std.testing.expectEqual(123, svc.x);

    ct.deinit();
    try std.testing.expect(Svc.deinit_called);
}
