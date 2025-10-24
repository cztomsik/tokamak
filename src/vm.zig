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

pub const ValueKind = enum {
    undefined,
    null,
    bool,
    number,
    shortstring,
    string,
    fun,
    err,
    array,
    object,
};

pub const Prop = struct {
    key: []const u8,
    value: Value,
};

pub const HeapValue = union(enum) {
    string: []u8,
    array: []Value, // TODO: std.ArrayList(Value)?
    object: []Prop, // TODO: std.StringHashMap(Value)?
    fun: Fun,
    err: Error,
};

// JSC-style layout (I think)
//   special values in low range, pointers direct (no tagging), all ptrs are
//   align(4) so we can use those bits
//   https://bun.com/blog/how-bun-supports-v8-apis-without-using-v8-part-1#jsvalue
// See also:
//   https://www.iro.umontreal.ca/~feeley/papers/MelanconSerranoFeeleyOOPSLA25.pdf
//   https://clementbera.wordpress.com/2018/11/09/64-bits-immediate-floats/
//   https://medium.com/@kannanvijayan/exboxing-bridging-the-divide-between-tag-boxing-and-nan-boxing-07e39840e0ca
pub const Value = packed union {
    raw: u64,
    number: f64,

    pub const @"undefined": Value = .{ .raw = 0x0A };
    pub const @"null": Value = .{ .raw = 0x02 };
    pub const @"false": Value = .{ .raw = 0x06 };
    pub const @"true": Value = .{ .raw = 0x07 };

    // Pointer mask: upper 16 bits = 0, bottom 2 bits = 0 (4-byte aligned)
    const POINTER_MASK: u64 = 0x0000FFFFFFFFFFFC;

    // By adding 7 * 2^48 to all doubles, we shift them from range 0x0000..0x7FF8
    // up to range 0x0007..0xFFFF, freeing up 0x0000..0x0006 for other uses.
    const DOUBLE_ENCODE_OFFSET: u64 = 0x0007000000000000;

    // Short string constants (auxillary space: 0x0001..0x0005)
    const MIN_AUX_TAG: u32 = 0x00010000;
    const SHORT_STRING_MAX_LEN: usize = 4;

    // Minimum value for encoded numbers (integers and doubles)
    const MIN_NUMBER: u64 = 0x0006000000000000;

    // TODO: fromPrimitive()? or just from(anytype) and comptime-fail if it's not supported?
    pub fn fromBool(b: bool) Value {
        return if (b) .true else .false;
    }

    pub fn fromNumber(n: f64) Value {
        var val = Value{ .number = n };
        val.raw += DOUBLE_ENCODE_OFFSET;
        return val;
    }

    pub fn asNumber(self: Value) f64 {
        std.debug.assert(self.kind() == .number);
        var val = self;
        val.raw -= DOUBLE_ENCODE_OFFSET;
        return val.number;
    }

    pub fn fromHeap(heap: *HeapValue) Value {
        const addr = @intFromPtr(heap);
        std.debug.assert(addr & 0x3 == 0);
        std.debug.assert(addr & 0xFFFF000000000000 == 0);
        return .{ .raw = addr };
    }

    pub fn fromShortString(str: []const u8) ?Value {
        if (str.len > SHORT_STRING_MAX_LEN) return null;

        const len: u32 = @intCast(str.len);
        const tag: u32 = MIN_AUX_TAG + len;
        var raw: u64 = @as(u64, tag) << 32;

        for (str, 0..) |byte, i| {
            const shift: u6 = @intCast(i * 8);
            raw |= @as(u64, byte) << shift;
        }

        return .{ .raw = raw };
    }

    pub fn isShortString(self: Value) bool {
        const tag: u32 = @intCast((self.raw >> 32) & 0xFFFFFFFF);
        return tag >= MIN_AUX_TAG and tag <= MIN_AUX_TAG + SHORT_STRING_MAX_LEN;
    }

    pub fn asShortString(self: Value) []const u8 {
        std.debug.assert(self.isShortString());

        const tag: u32 = @intCast((self.raw >> 32) & 0xFFFFFFFF);
        const len: usize = tag - MIN_AUX_TAG;
        const bytes: *const [8]u8 = @ptrCast(&self.raw);
        return bytes[0..len];
    }

    pub fn kind(self: Value) ValueKind {
        if (self.raw == Value.undefined.raw) return .undefined;
        if (self.raw == Value.null.raw) return .null;
        if (self.raw == Value.false.raw) return .bool;
        if (self.raw == Value.true.raw) return .bool;
        if (self.raw >= MIN_NUMBER) return .number;
        if (self.isShortString()) return .shortstring;

        if (self.isPointer()) {
            const heap = self.getHeap().?;
            return switch (heap.*) {
                .string => .string,
                .array => .array,
                .object => .object,
                .fun => .fun,
                .err => .err,
            };
        }

        return .undefined;
    }

    fn isPointer(self: Value) bool {
        return (self.raw & ~POINTER_MASK) == 0 and self.raw != 0;
    }

    fn getHeap(self: Value) ?*HeapValue {
        if (!self.isPointer()) return null;
        return @ptrFromInt(self.raw);
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
                .number => self.asNumber(),
                else => error.TypeError,
            },
            []const u8 => switch (self.kind()) {
                .shortstring => self.asShortString(),
                .string => self.getHeap().?.string,
                else => error.TypeError,
            },
            []const Value => switch (self.kind()) {
                .array => self.getHeap().?.array,
                else => error.TypeError,
            },
            []const Prop => switch (self.kind()) {
                .object => self.getHeap().?.object,
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
            .number => try writer.print("{d}", .{self.asNumber()}),
            .shortstring => try writer.writeAll(self.asShortString()),
            .string => {
                const heap = self.getHeap().?;
                try writer.writeAll(heap.string);
            },
            .array => try writer.writeAll("[array]"),
            .object => try writer.writeAll("[object]"),
            .fun => try writer.writeAll("[function]"),
            .err => {
                const heap = self.getHeap().?;
                try writer.print("error: {s}", .{@errorName(heap.err)});
            },
        }
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self.kind()) {
            .undefined, .null => false,
            .bool => self.raw == Value.true.raw,
            .number => self.asNumber() != 0,
            .shortstring => self.asShortString().len > 0,
            .string => self.getHeap().?.string.len > 0,
            .array => self.getHeap().?.array.len > 0,
            .object => true,
            .fun => true,
            .err => false,
        };
    }

    pub fn get(self: Value, key: Value) ?Value {
        // TODO: key.into() shortstring footgun
        if (self.kind() == .object) {
            const key_str = key.into([]const u8) catch return null;
            for (self.getHeap().?.object) |prop| {
                if (std.mem.eql(u8, prop.key, key_str)) {
                    return prop.value;
                }
            }
        }

        if (self.kind() == .array) {
            const index = key.into(f64) catch return null;
            const idx: usize = @intFromFloat(index);
            const arr = self.getHeap().?.array;
            if (idx < arr.len) {
                return arr[idx];
            }
        }

        return null;
    }

    pub fn hash(self: Value) u64 {
        return switch (self.kind()) {
            .string => std.hash.Wyhash.hash(0, self.into([]const u8) catch unreachable),
            else => self.raw,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.kind() == .shortstring and b.kind() == .shortstring) {
            return a.raw == b.raw;
        }

        if ((a.kind() == .shortstring or a.kind() == .string) and
            (b.kind() == .shortstring or b.kind() == .string))
        {
            return std.mem.eql(
                u8,
                a.into([]const u8) catch unreachable,
                b.into([]const u8) catch unreachable,
            );
        }

        return a.raw == b.raw;
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
    store: Value,
    load: Value,
    call: Value, // TODO: argless?
    pop,
    dup,
    get,
};

pub const Context = struct {
    parent: ?*Context,
    gpa: std.mem.Allocator,
    stack: std.ArrayList(Value),
    env: std.HashMap(Value, Value, HashCx, std.hash_map.default_max_load_percentage),
    heap: std.ArrayList(*HeapValue),

    // TODO: *const T footgun (see smol.zig)
    const HashCx = struct {
        pub fn hash(_: HashCx, v: Value) u64 {
            return v.hash();
        }

        pub fn eql(_: HashCx, a: Value, b: Value) bool {
            return a.eql(b);
        }
    };

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
                .array => |a| self.gpa.free(a),
                .object => |o| self.gpa.free(o),
                .fun, .err => {},
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
            if (Value.fromShortString(input)) |short_val| {
                return short_val;
            }

            const heap_val = try self.gpa.create(HeapValue);
            errdefer self.gpa.destroy(heap_val);

            heap_val.* = .{ .string = try self.gpa.dupe(u8, input) };
            try self.heap.append(self.gpa, heap_val);
            return Value.fromHeap(heap_val);
        }

        if (meta.isOptional(T)) {
            return if (input) |v| try self.value(v) else Value.null;
        }

        if (meta.isSlice(T)) {
            const heap_val = try self.gpa.create(HeapValue);
            errdefer self.gpa.destroy(heap_val);

            const array = try self.gpa.alloc(Value, input.len);
            errdefer self.gpa.free(array);

            for (input, 0..) |item, i| {
                array[i] = try self.value(item);
            }

            heap_val.* = .{ .array = array };
            try self.heap.append(self.gpa, heap_val);
            return Value.fromHeap(heap_val);
        }

        return switch (@typeInfo(T)) {
            .void => Value.undefined,
            .null => Value.null,
            .bool => Value.fromBool(input),
            .comptime_int, .int => Value.fromNumber(@floatFromInt(input)),
            .comptime_float, .float => Value.fromNumber(@floatCast(input)),
            .error_union => if (input) |v| try self.value(v) else |e| try self.value(e),
            .error_set => {
                const heap_val = try self.gpa.create(HeapValue);
                errdefer self.gpa.destroy(heap_val);

                heap_val.* = .{ .err = error.UnexpectedError };
                try self.heap.append(self.gpa, heap_val);
                return Value.fromHeap(heap_val);
            },
            .@"fn" => {
                const heap_val = try self.gpa.create(HeapValue);
                errdefer self.gpa.destroy(heap_val);

                heap_val.* = .{ .fun = Fun.wrap(input) };
                try self.heap.append(self.gpa, heap_val);
                return Value.fromHeap(heap_val);
            },
            .pointer => try self.value(input.*),
            .array => |a| self.value(@as([]const a.child, &input)),
            .@"struct" => |s| {
                const heap_val = try self.gpa.create(HeapValue);
                errdefer self.gpa.destroy(heap_val);

                const props = try self.gpa.alloc(Prop, s.fields.len);
                errdefer self.gpa.free(props);

                inline for (s.fields, 0..) |f, i| {
                    props[i] = .{
                        .key = f.name,
                        .value = try self.value(@field(input, f.name)),
                    };
                }

                heap_val.* = .{ .object = props };
                try self.heap.append(self.gpa, heap_val);
                return Value.fromHeap(heap_val);
            },
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
        const key = try self.value(name);
        try self.env.put(key, try self.value(val));
    }

    pub fn get(self: *Context, name: []const u8) ?Value {
        const key = self.value(name) catch return null;
        if (self.env.get(key)) |val| return val;
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
                    const res = try self.call(try ident.into([]const u8));
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
                .get => {
                    const key = self.pop() orelse return Error.StackUnderflow;
                    const obj = self.pop() orelse return Error.StackUnderflow;
                    const val = obj.get(key) orelse return Error.UndefinedVar;
                    try self.push(val);
                },
            }
        }

        return self.pop() orelse .undefined;
    }

    pub fn call(self: *Context, fn_name: []const u8) Error!Value {
        const key = try self.value(fn_name);
        if (self.env.get(key)) |f| {
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
        .{ .call = try vm.value("+") },
        .{ .push = try vm.value(2.0) },
        .{ .call = try vm.value("+") },
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
