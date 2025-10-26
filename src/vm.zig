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

pub const Prop = struct {
    key: []const u8,
    value: Value,
};

pub const ShortString = struct {
    len: u8,
    data: [7]u8 = [_]u8{0} ** 7,

    pub fn init(str: []const u8) ?ShortString {
        if (str.len > 7) return null;

        var result = ShortString{ .len = @intCast(str.len) };
        @memcpy(result.data[0..str.len], str);
        return result;
    }

    pub fn slice(self: *const ShortString) []const u8 {
        return self.data[0..self.len];
    }
};

// NOTE: NaN-boxing is cool but I don't think it's worth the complexity.
//       Our scopes are short-lived and if anything, we will rather benefit
//       from longer inline strings.
pub const Value = union(enum) {
    undefined,
    null,
    bool: bool,
    number: f64,
    shortstring: ShortString,
    string: []u8,
    array: []Value, // TODO: std.ArrayList(Value)?
    object: []Prop, // TODO: std.StringHashMap(Value)?
    fun: Fun,
    err: anyerror,

    pub const @"true": Value = .{ .bool = true };
    pub const @"false": Value = .{ .bool = false };

    pub fn expect(self: *const Value, comptime kind: std.meta.Tag(Value)) !@FieldType(Value, @tagName(kind)) {
        return switch (self.*) {
            kind => |v| v,
            else => error.TypeError,
        };
    }

    // TODO: I am still not sure/happy about this
    pub fn into(self: *const Value, comptime T: type) Error!T {
        return switch (T) {
            Value => self.*,
            void => self.expect(.undefined),
            bool => self.expect(.bool),
            f64 => self.expect(.number),

            []const u8 => switch (self.*) {
                // NOTE: |ss| ss.slice() would point to the temp memory!
                .shortstring => self.shortstring.slice(),
                .string => |s| s,
                else => error.TypeError,
            },

            []const Value => self.expect(.array),
            []const Prop => self.expect(.object),
            else => @compileError("TODO Value.into " ++ @typeName(T)),
        };
    }

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .undefined => try writer.writeAll("undefined"),
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.print("{}", .{b}),
            .number => |n| try writer.print("{d}", .{n}),
            .shortstring => |ss| try writer.writeAll(ss.slice()),
            .string => |s| try writer.writeAll(s),
            .array => try writer.writeAll("[array]"),
            .object => try writer.writeAll("[object]"),
            .fun => try writer.writeAll("[function]"),
            .err => |e| try writer.print("error: {s}", .{@errorName(e)}),
        }
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .undefined, .null => false,
            .bool => |b| b,
            .number => |n| n != 0,
            inline .shortstring, .string, .array => |s| s.len > 0,
            else => true,
        };
    }

    // TODO: IDK, maybe we should keep this separate for each kind, and maybe
    //       even keep these methods in the inner structs.
    pub fn get(self: Value, key: Value) ?Value {
        switch (self) {
            .object => |obj| {
                const key_str = key.into([]const u8) catch return null;
                for (obj) |prop| {
                    if (std.mem.eql(u8, prop.key, key_str)) {
                        return prop.value;
                    }
                }
            },
            .array => |arr| {
                const index = key.into(f64) catch return null;
                const idx: usize = @intFromFloat(index);
                if (idx < arr.len) {
                    return arr[idx];
                }
            },
            else => {},
        }

        return null;
    }
};

pub const Fun = union(enum) {
    native: *const fn (*Context) Error!void,
    compiled: struct {
        arity: u8,
        code: []const Op,
    },

    fn wrap(fun: anytype) Fun {
        const H = struct {
            fn wrap(vm: *Context) Error!void {
                const Args = std.meta.ArgsTuple(@TypeOf(fun));
                var args: Args = undefined;

                inline for (0..args.len) |i| {
                    const j = args.len - i - 1;
                    const A = @TypeOf(args[j]);

                    if (A == *Context) {
                        args[j] = vm;
                    } else {
                        const val = try vm.pop();
                        args[j] = try val.into(A);
                    }
                }

                const res = @call(.auto, fun, args);
                return vm.push(try vm.value(res));
            }
        };

        return .{ .native = H.wrap };
    }
};

pub const Op = union(enum) {
    push: Value,
    store: []const u8,
    load: []const u8,
    call,
    dup,
    get,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    stack: std.ArrayList(Value),
    env: std.AutoHashMap(ShortString, Value),

    pub fn init(arena: std.mem.Allocator) Context {
        return .{
            .arena = arena,
            .stack = .{},
            .env = .init(arena),
        };
    }

    pub fn deinit(self: *Context) void {
        self.stack.deinit(self.arena);
        self.env.deinit();
    }

    pub fn value(self: *Context, input: anytype) Error!Value {
        const T = @TypeOf(input);

        if (T == Value) return input;

        if (meta.isString(T)) {
            if (ShortString.init(input)) |short| {
                return .{ .shortstring = short };
            }

            return .{ .string = try self.arena.dupe(u8, input) };
        }

        if (meta.isOptional(T)) {
            return if (input) |v| try self.value(v) else .{ .null = {} };
        }

        if (meta.isSlice(T)) {
            const array = try self.arena.alloc(Value, input.len);

            for (input, 0..) |item, i| {
                array[i] = try self.value(item);
            }

            return .{ .array = array };
        }

        return switch (@typeInfo(T)) {
            .void => .{ .undefined = {} },
            .null => .{ .null = {} },
            .bool => .{ .bool = input },
            .comptime_int, .int => .{ .number = @floatFromInt(input) },
            .comptime_float, .float => .{ .number = @floatCast(input) },
            .error_union => if (input) |v| try self.value(v) else |e| try self.value(e),
            .error_set => .{ .err = error.UnexpectedError },
            .@"fn" => .{ .fun = Fun.wrap(input) },
            .pointer => try self.value(input.*),
            .array => |a| self.value(@as([]const a.child, &input)),
            .@"union" => {
                if (T == Fun) {
                    return .{ .fun = input };
                }

                @compileError("TODO: Context.value (union) " ++ @typeName(T));
            },
            .@"struct" => |s| {
                const props = try self.arena.alloc(Prop, s.fields.len);

                inline for (s.fields, 0..) |f, i| {
                    props[i] = .{
                        .key = f.name,
                        .value = try self.value(@field(input, f.name)),
                    };
                }

                return .{ .object = props };
            },
            else => @compileError("TODO: Context.value " ++ @typeName(T)),
        };
    }

    pub fn define(self: *Context, name: []const u8, val: anytype) Error!void {
        const key = ShortString.init(name) orelse return error.TypeError;
        try self.env.put(key, try self.value(val));
    }

    pub fn get(self: *Context, name: []const u8) Value {
        const key = ShortString.init(name) orelse return .undefined;
        if (self.env.get(key)) |val| return val;
        return .undefined;
    }

    pub fn eval(self: *Context, code: []const Op) Error!Value {
        try self.exec(code);
        return self.pop();
    }

    fn exec(self: *Context, code: []const Op) !void {
        for (code) |op| {
            switch (op) {
                .push => |val| try self.push(val),
                .store => |ident| {
                    try self.define(ident, try self.pop());
                },
                .load => |ident| {
                    try self.push(self.get(ident));
                },
                .call => {
                    const val = try self.pop();
                    switch (try val.expect(.fun)) {
                        .native => |nfun| try nfun(self),
                        .compiled => |cfun| if (self.stack.items.len >= cfun.arity) try self.exec(cfun.code) else return error.StackUnderflow,
                    }
                },
                .dup => {
                    const val = try self.pop();
                    try self.push(val);
                    try self.push(val);
                },
                .get => {
                    const key = try self.pop();
                    const obj = try self.pop();
                    const val = obj.get(key) orelse return Error.UndefinedVar;
                    try self.push(val);
                },
            }
        }
    }

    fn push(self: *Context, val: Value) !void {
        return self.stack.append(self.arena, val);
    }

    fn pop(self: *Context) !Value {
        return self.stack.pop() orelse error.StackUnderflow;
    }
};

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Context.init(arena.allocator());
    defer vm.deinit();

    const H = struct {
        fn add(a: f64, b: f64) f64 {
            return a + b;
        }
    };
    try vm.define("+", H.add);

    const res = try vm.eval(&.{
        .{ .push = try vm.value(1) },
        .{ .push = try vm.value(2.5) },
        .{ .load = "+" },
        .call,
    });
    try std.testing.expectEqual(3.5, res.number);

    const res2 = try vm.eval(&.{
        .{ .push = try vm.value(5.0) },
        .{ .push = try vm.value(3.0) },
        .{ .load = "+" },
        .call,
        .{ .push = try vm.value(2.0) },
        .{ .load = "+" },
        .call,
    });
    try std.testing.expectEqual(10.0, res2.number);
}
