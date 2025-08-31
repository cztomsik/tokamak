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

// TODO: NaN boxing
pub const Value = union(enum) {
    undefined,
    null,
    bool: bool,
    number: f64,
    string: []const u8, // TODO: this should be owned
    fun: Fun,
    err: Error,
    // TODO: arrays/slices

    fn expect(self: Value, comptime kind: std.meta.FieldEnum(Value)) !std.meta.fieldInfo(Value, kind).type {
        return switch (self) {
            kind => |t| t,
            else => error.TypeError,
        };
    }

    pub fn from(val: anytype) Value {
        const T = @TypeOf(val);

        if (T == Value) return val;
        if (meta.isString(T)) return .{ .string = val };
        if (meta.isOptional(T)) return if (val) |v| from(v) else .null;
        if (meta.isSlice(T)) @compileError("TODO");

        return switch (@typeInfo(T)) {
            .void => .undefined,
            .null => .null,
            .bool => .{ .bool = val },
            .comptime_int, .int => .{ .number = @floatFromInt(val) },
            .comptime_float, .float => .{ .number = @floatCast(val) },
            .error_union => if (val) |v| from(v) else |e| from(e),
            .error_set => .{ .err = error.UnexpectedError },
            .@"fn" => .{ .fun = .wrap(val) },
            .pointer => from(val.*),
            else => @compileError("TODO: Value.from " ++ @typeName(T)),
        };
    }

    pub fn into(self: Value, comptime T: type) Error!T {
        return switch (T) {
            Value => self,
            void => self.expect(.undefined),
            bool => self.expect(.bool),
            f64 => self.expect(.number),
            []const u8 => self.expect(.string),
            else => @compileError("TODO Value.into " ++ @typeName(T)),
        };
    }
};

pub const Fun = union(enum) {
    native: *const fn (*VM) Error!Value,
    compiled: struct {
        arity: u8,
        code: []const Op,
    },

    fn wrap(fun: anytype) Fun {
        const H = struct {
            fn wrap(vm: *VM) Error!Value {
                const Args = std.meta.ArgsTuple(@TypeOf(fun));
                var args: Args = undefined;

                inline for (std.meta.fields(Args), 0..) |f, i| {
                    if (f.type == *VM) {
                        args[i] = vm;
                        continue;
                    }

                    const val = vm.pop() orelse return error.TypeError;
                    args[i] = try val.into(f.type);
                }

                const res = @call(.auto, fun, args);
                return Value.from(res);
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

pub const VM = struct {
    gpa: std.mem.Allocator,
    stack: std.array_list.Managed(Value),
    env: std.AutoHashMap(Ident, Value),

    pub fn init(gpa: std.mem.Allocator) VM {
        return .{
            .gpa = gpa,
            .stack = .init(gpa),
            .env = .init(gpa),
        };
    }

    pub fn deinit(self: *VM) void {
        self.stack.deinit();
        self.env.deinit();
    }

    pub fn define(self: *VM, name: []const u8, val: anytype) Error!void {
        try self.env.put(Ident.parse(name), Value.from(val));
    }

    pub fn get(self: *VM, name: []const u8) ?Value {
        return self.env.get(Ident.parse(name));
    }

    pub fn push(self: *VM, val: anytype) Error!void {
        return self.stack.append(Value.from(val));
    }

    pub fn pop(self: *VM) ?Value {
        return self.stack.pop();
    }

    pub fn eval(self: *VM, code: []const Op) Error!Value {
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

    pub fn call(self: *VM, fn_name: []const u8) Error!Value {
        if (self.env.get(Ident.parse(fn_name))) |f| {
            return switch (f.fun) {
                .native => |fun| fun(self),
                .compiled => |fun| if (self.stack.items.len > fun.arity) self.eval(fun.code) else error.StackUnderflow,
            };
        }

        return Error.UndefinedFunction;
    }
};

test {
    var vm = VM.init(std.testing.allocator);
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
    try std.testing.expectEqual(3.5, res.number);

    const ops: []const Op = &.{
        .{ .push = Value.from(5.0) },
        .{ .push = Value.from(3.0) },
        .{ .call = Ident.parse("+") },
        .{ .push = Value.from(2.0) },
        .{ .call = Ident.parse("+") },
    };

    const result = try vm.eval(ops);
    try std.testing.expectEqual(10.0, result.number);
}
