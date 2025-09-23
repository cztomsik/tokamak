// Simple, general-purpose stack-based VM.

const std = @import("std");
const meta = @import("meta.zig");
const util = @import("util.zig");

pub const Error = error{
    TypeError,
    UndefinedFunction,
    UndefinedVar,
    StackUnderflow,
    OutOfMemory,
    UnexpectedError,
};

pub const Ident = enum(u128) {
    _,

    pub fn parse(ident: []const u8) Ident {
        const x = util.Smol128.initShort(ident) orelse util.Smol128.initComptime("unknown");
        return @enumFromInt(x.raw);
    }

    pub fn name(self: *const Ident) []const u8 {
        return util.Smol128.str(@ptrCast(self));
    }
};

pub const ValueKind = enum {
    undefined,
    null,
    bool,
    number,
    string,
    fun,
    err,
};

pub const HeapValue = union(enum) {
    string: []u8,
    fun: Fun,
    err: Error,
};

pub const Value = packed union {
    raw: u64,
    number: f64,

    const QNAN: u64 = 0x7FF8000000000000;
    const PTR_TAG_MASK: u64 = 0xFFFF000000000000;
    const PTR_TAG: u64 = 0x7FFC000000000000;

    pub const @"undefined": Value = .{ .raw = QNAN | 0 };
    pub const @"null": Value = .{ .raw = QNAN | 1 };
    pub const @"false": Value = .{ .raw = QNAN | 2 };
    pub const @"true": Value = .{ .raw = QNAN | 3 };

    // TODO: fromPrimitive()? or just from(anytype) and comptime-fail if it's not supported?
    pub fn fromBool(b: bool) Value {
        return if (b) .true else .false;
    }

    pub fn fromNumber(n: f64) Value {
        return .{ .number = n };
    }

    pub fn fromHeap(heap: *HeapValue) Value {
        const addr = @intFromPtr(heap);
        return .{ .raw = PTR_TAG | (addr & 0xFFFFFFFFFFFF) };
    }

    pub fn kind(self: Value) ValueKind {
        if (self.raw == Value.undefined.raw) return .undefined;
        if (self.raw == Value.null.raw) return .null;
        if (self.raw == Value.false.raw) return .bool;
        if (self.raw == Value.true.raw) return .bool;

        if ((self.raw & PTR_TAG_MASK) == PTR_TAG) {
            const heap = self.getHeap().?;
            return switch (heap.*) {
                .string => .string,
                .fun => .fun,
                .err => .err,
            };
        }
        return .number;
    }

    fn getHeap(self: Value) ?*HeapValue {
        if ((self.raw & PTR_TAG_MASK) != PTR_TAG) return null;
        const addr = self.raw & 0xFFFFFFFFFFFF;
        return @ptrFromInt(addr);
    }

    pub fn into(self: Value, comptime T: type) Error!T {
        // TODO: we could add Value.expect(kind) helper
        return switch (T) {
            Value => self,
            void => switch (self.kind()) {
                .undefined => {},
                else => error.TypeError,
            },
            bool => switch (self.kind()) {
                .bool => self == .true,
                else => error.TypeError,
            },
            f64 => switch (self.kind()) {
                .number => self.number,
                else => error.TypeError,
            },
            []const u8 => switch (self.kind()) {
                .string => self.getHeap().?.string,
                else => error.TypeError,
            },
            else => @compileError("TODO Value.into " ++ @typeName(T)),
        };
    }

    pub fn format(self: Value, writer: anytype) !void {
        switch (self.kind()) {
            .undefined => try writer.writeAll("undefined"),
            .null => try writer.writeAll("null"),
            .bool => try writer.print("{}", .{self.raw == Value.true.raw}),
            .number => try writer.print("{d}", .{self.number}),
            .string => {
                const heap = self.getHeap().?;
                try writer.writeAll(heap.string);
            },
            .fun => try writer.writeAll("[function]"),
            .err => {
                const heap = self.getHeap().?;
                try writer.print("error: {s}", .{@errorName(heap.err)});
            },
        }
    }
};

pub const Fun = union(enum) {
    native: *const fn (*Context) Error!Value,
    compiled: struct {
        arity: u8,
        code: []const Op,
    },

    fn wrap(fun: anytype) Fun {
        const H = struct {
            fn wrap(vm: *Context) Error!Value {
                const Args = std.meta.ArgsTuple(@TypeOf(fun));
                var args: Args = undefined;

                // First, collect all non-Context values from stack
                var values: [args.len]?Value = .{null} ** args.len;
                var value_count: usize = 0;

                inline for (std.meta.fields(Args)) |f| {
                    if (f.type != *Context) {
                        values[value_count] = vm.pop() orelse return error.TypeError;
                        value_count += 1;
                    }
                }

                // Now assign arguments in correct order
                var value_index: usize = value_count;
                inline for (std.meta.fields(Args), 0..) |f, i| {
                    if (f.type == *Context) {
                        args[i] = vm;
                    } else {
                        value_index -= 1;
                        args[i] = try values[value_index].?.into(f.type);
                    }
                }

                const res = @call(.auto, fun, args);
                return vm.value(res);
            }
        };

        return .{ .native = H.wrap };
    }
};

pub const Op = union(enum) {
    push: Value,
    store: Ident,
    load: Ident,
    call: Ident, // TODO: argless?
    pop,
    dup,
};

pub const Context = struct {
    parent: ?*Context,
    gpa: std.mem.Allocator,
    stack: std.ArrayList(Value),
    env: std.AutoHashMap(Ident, Value),
    heap: std.ArrayList(*HeapValue),

    pub fn init(gpa: std.mem.Allocator) Context {
        return .{
            .parent = null,
            .gpa = gpa,
            .stack = .{},
            .env = .init(gpa),
            .heap = .{},
        };
    }

    pub fn deinit(self: *Context) void {
        // Free all heap allocations
        for (self.heap.items) |heap_val| {
            switch (heap_val.*) {
                .string => |s| self.gpa.free(s),
                .fun, .err => {}, // No additional cleanup needed
            }
            self.gpa.destroy(heap_val);
        }
        self.heap.deinit(self.gpa);

        self.stack.deinit(self.gpa);
        self.env.deinit();
    }

    pub fn value(self: *Context, input: anytype) Error!Value {
        const T = @TypeOf(input);

        if (T == Value) return input;

        if (meta.isString(T)) {
            const heap_val = try self.gpa.create(HeapValue);
            heap_val.* = .{ .string = try self.gpa.dupe(u8, input) };
            try self.heap.append(self.gpa, heap_val);
            return Value.fromHeap(heap_val);
        }

        if (meta.isOptional(T)) return if (input) |v| try self.value(v) else Value.null;
        if (meta.isSlice(T)) @compileError("TODO");

        return switch (@typeInfo(T)) {
            .void => Value.undefined,
            .null => Value.null,
            .bool => Value.fromBool(input),
            .comptime_int, .int => Value.fromNumber(@floatFromInt(input)),
            .comptime_float, .float => Value.fromNumber(@floatCast(input)),
            .error_union => if (input) |v| try self.value(v) else |e| try self.value(e),
            .error_set => blk: {
                const heap_val = try self.gpa.create(HeapValue);
                heap_val.* = .{ .err = error.UnexpectedError };
                try self.heap.append(self.gpa, heap_val);
                break :blk Value.fromHeap(heap_val);
            },
            .@"fn" => blk: {
                const heap_val = try self.gpa.create(HeapValue);
                heap_val.* = .{ .fun = Fun.wrap(input) };
                try self.heap.append(self.gpa, heap_val);
                break :blk Value.fromHeap(heap_val);
            },
            .pointer => try self.value(input.*),
            else => @compileError("TODO: Context.value " ++ @typeName(T)),
        };
    }

    pub fn child(self: *Context, gpa: std.mem.Allocator) Context {
        return .{
            .parent = self,
            .gpa = gpa,
            .stack = .{},
            .env = .init(gpa),
            .heap = .{},
        };
    }

    pub fn define(self: *Context, name: []const u8, val: anytype) Error!void {
        try self.env.put(Ident.parse(name), try self.value(val));
    }

    pub fn get(self: *Context, name: []const u8) ?Value {
        const ident = Ident.parse(name);
        if (self.env.get(ident)) |val| return val;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    pub fn push(self: *Context, val: anytype) Error!void {
        return self.stack.append(self.gpa, try self.value(val));
    }

    pub fn pop(self: *Context) ?Value {
        return self.stack.pop();
    }

    pub fn eval(self: *Context, code: []const Op) Error!Value {
        for (code) |op| {
            switch (op) {
                .push => |val| try self.push(val),
                .call => |ident| {
                    const res = try self.call(ident.name());
                    try self.push(res);
                },
                .load => |ident| {
                    const val = self.env.get(ident) orelse return Error.UndefinedVar;
                    try self.push(val);
                },
                .store => |ident| {
                    const val = self.pop() orelse return Error.StackUnderflow;
                    try self.env.put(ident, val);
                },
                .pop => {
                    _ = self.pop() orelse return Error.StackUnderflow;
                },
                .dup => {
                    const val = self.pop() orelse return Error.StackUnderflow;
                    try self.push(val);
                    try self.push(val);
                },
            }
        }

        return self.pop() orelse .undefined;
    }

    pub fn call(self: *Context, fn_name: []const u8) Error!Value {
        if (self.env.get(Ident.parse(fn_name))) |f| {
            switch (f.kind()) {
                .fun => {
                    const heap = f.getHeap().?;
                    return switch (heap.fun) {
                        .native => |nfun| nfun(self),
                        .compiled => |cfun| if (self.stack.items.len >= cfun.arity) self.eval(cfun.code) else error.StackUnderflow,
                    };
                },
                else => {},
            }
        }

        return Error.UndefinedFunction;
    }
};

test {
    var vm = Context.init(std.testing.allocator);
    defer vm.deinit();

    try vm.push(1);
    try vm.push(2.5);

    const H = struct {
        fn add(a: f64, b: f64) f64 {
            return a + b;
        }
    };
    try vm.define("+", H.add);

    const res = try vm.call("+");
    try std.testing.expectEqual(3.5, try res.into(f64));

    const ops: []const Op = &.{
        .{ .push = try vm.value(5.0) },
        .{ .push = try vm.value(3.0) },
        .{ .call = Ident.parse("+") },
        .{ .push = try vm.value(2.0) },
        .{ .call = Ident.parse("+") },
    };

    const result = try vm.eval(ops);
    try std.testing.expectEqual(10.0, try result.into(f64));
}

test "parent child context" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    try parent.define("x", 42);

    var child = parent.child(std.testing.allocator);
    defer child.deinit();

    try child.define("y", 24);

    // Child can access parent variables
    try std.testing.expectEqual(42.0, try child.get("x").?.into(f64));
    try std.testing.expectEqual(24.0, try child.get("y").?.into(f64));

    // Parent cannot access child variables
    try std.testing.expect(parent.get("y") == null);
    try std.testing.expectEqual(42.0, try parent.get("x").?.into(f64));

    // Child can shadow parent variables
    try child.define("x", 100);
    try std.testing.expectEqual(100.0, try child.get("x").?.into(f64));
    try std.testing.expectEqual(42.0, try parent.get("x").?.into(f64));
}
