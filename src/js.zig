// KISS, JS-like, stack-based VM. Let's don't worry about tokenization/parsing
// for now, we can do that later.
// TODO: Token, Tokenizer, Parser, Expr

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

const Ident = enum(u128) {
    _,

    pub fn parse(ident: []const u8) Ident {
        const x = util.Smol128.initShort(ident) orelse util.Smol128.initComptime("unknown");
        return @enumFromInt(x.raw);
    }

    pub fn name(self: *const Ident) []const u8 {
        return util.Smol128.str(@ptrCast(self));
    }
};

const Value = union(enum) {
    undefined,
    bool: bool,
    number: f64,
    string: []const u8,
    fun: Fun,
    err: Error,

    fn from(val: anytype) Value {
        const T = @TypeOf(val);

        if (T == Value) {
            return val;
        }

        if (T == []const Op) {
            return .{ .fun = .{ .code = val } };
        }

        if (meta.isString(T)) {
            return .{ .string = val };
        }

        if (meta.isSlice(T)) {
            @compileError("TODO");
        }

        return switch (@typeInfo(T)) {
            .void => .undefined,
            .bool => .{ .bool = val },
            .comptime_int, .int, .comptime_float, .float => .{ .number = val },
            .error_union => if (val) |v| from(v) else |e| from(e),
            .error_set => .{ .err = error.UnexpectedError },
            .@"fn" => .{ .fun = .native(val) },
            .pointer => from(val.*),
            else => @compileError("TODO: Value.from " ++ @typeName(T)),
        };
    }

    fn into(self: Value, comptime T: type) Error!T {
        return switch (T) {
            Value => self,
            void => self.expect(.undefined),
            bool => self.expect(.bool),
            f64 => self.expect(.number),
            []const u8 => self.expect(.string),
            else => @compileError("TODO Value.into " ++ @typeName(T)),
        };
    }

    fn expect(self: Value, comptime kind: std.meta.FieldEnum(Value)) !std.meta.fieldInfo(Value, kind).type {
        return switch (self) {
            kind => |t| t,
            else => error.TypeError,
        };
    }
};

const Fun = union(enum) {
    native_fn: *const fn (*VM) Error!Value,
    code: []const Op,

    fn native(fun: anytype) Fun {
        const H = struct {
            fn wrap(vm: *VM) Error!Value {
                const Args = std.meta.ArgsTuple(@TypeOf(fun));
                var args: Args = undefined;
                const fields = std.meta.fields(Args);
                inline for (fields, 0..) |field, i| {
                    const val = vm.pop() orelse return error.TypeError;
                    args[i] = try val.into(field.type);
                }

                const res = @call(.auto, fun, args);
                return Value.from(res);
            }
        };

        return .{ .native_fn = H.wrap };
    }
};

const Op = union(enum) {
    push: Value,
    call: Ident,
    load: Ident,
    store: Ident,
    pop,
    dup,
};

const VM = struct {
    gpa: std.mem.Allocator,
    stack: std.ArrayList(Value),
    env: std.AutoHashMap(Ident, Value),

    pub fn init(gpa: std.mem.Allocator) Error!VM {
        var self = initEmpty(gpa);
        try Builtins.defineAll(&self);
        return self;
    }

    pub fn initEmpty(gpa: std.mem.Allocator) VM {
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
                .native_fn => |fun| fun(self),
                .code => |ops| self.eval(ops),
            };
        }

        return Error.UndefinedFunction;
    }
};

const Builtins = struct {
    pub fn @"+"(a: f64, b: f64) f64 {
        return a + b;
    }

    pub fn @"-"(a: f64, b: f64) f64 {
        return a - b;
    }

    pub fn @"*"(a: f64, b: f64) f64 {
        return a * b;
    }

    pub fn @"/"(a: f64, b: f64) f64 {
        return a / b;
    }

    pub fn print(val: Value) void {
        switch (val) {
            .undefined => std.debug.print("undefined\n", .{}),
            .bool => |b| std.debug.print("{}\n", .{b}),
            .number => |n| std.debug.print("{}\n", .{n}),
            .string => |s| std.debug.print("{s}\n", .{s}),
            .fun => std.debug.print("[function]\n", .{}),
            .err => |e| std.debug.print("error: {s}", .{@errorName(e)}),
        }
    }

    pub fn eval(vm: *VM, code: []const Op) Error!Value {
        return vm.eval(code);
    }

    fn defineAll(vm: *VM) Error!void {
        inline for (comptime std.meta.declarations(@This())) |d| {
            // TODO: Fix error union and then we can export this too?
            if (comptime std.mem.eql(u8, d.name, "eval")) continue;
            try vm.define(d.name, @field(@This(), d.name));
        }
    }
};

test VM {
    var js = try VM.init(std.testing.allocator);
    defer js.deinit();

    try js.push(1);
    try js.push(2.5);

    const res = try js.call("+");
    try std.testing.expectEqual(3.5, res.number);
}

test "VM.eval()" {
    var js = try VM.init(std.testing.allocator);
    defer js.deinit();

    const ops: []const Op = &.{
        .{ .push = Value.from(5.0) },
        .{ .push = Value.from(3.0) },
        .{ .call = Ident.parse("+") },
        .{ .push = Value.from(2.0) },
        .{ .call = Ident.parse("*") },
    };

    const result = try js.eval(ops);
    try std.testing.expectEqual(16.0, result.number);
}
