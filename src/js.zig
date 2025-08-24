// Tiny, JS-like execution context.
// TODO: Token, Tokenizer, Parser, Expr

const std = @import("std");
const meta = @import("meta.zig");
const util = @import("util.zig");
const VM = @import("vm.zig").VM;
const Value = @import("vm.zig").Value;

pub const Context = struct {
    vm: VM,

    pub fn init(gpa: std.mem.Allocator) !Context {
        var vm = VM.init(gpa);
        errdefer vm.deinit();

        inline for (comptime std.meta.declarations(Builtins)) |d| {
            try vm.define(d.name, @field(Builtins, d.name));
        }

        return .{
            .vm = vm,
        };
    }

    pub fn deinit(self: *Context) void {
        self.vm.deinit();
    }

    pub fn eval(self: *Context, expr: []const u8) !Value {
        _ = self; // autofix
        var tokenizer: Tokenizer = .{ .input = expr };
        const tok = tokenizer.next() orelse @panic("TODO");

        return switch (tok) {
            .number => |num| .{ .number = num },
            else => @panic("TODO"),
        };
    }

    pub fn print(self: *Context, writer: std.io.AnyWriter, val: Value) !void {
        _ = self; // autofix

        // TODO: move SOME of this to Value.fmt/debug() but js.print() should probably stay JS-specific
        try switch (val) {
            .undefined => writer.print("undefined", .{}),
            .null => writer.print("null", .{}),
            .bool => |b| writer.print("{}", .{b}),
            .number => |n| writer.print("{d}", .{n}),
            .string => |s| writer.print("{s}", .{s}),
            .fun => writer.print("[function]", .{}),
            .err => |e| writer.print("error: {s}", .{@errorName(e)}),
        };
    }
};

fn cx(vm: *VM) *Context {
    return @fieldParentPtr("vm", vm);
}

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

    pub fn print(vm: *VM, val: Value) !void {
        const w = std.io.getStdErr().writer().any();
        try cx(vm).print(w, val);
        try w.writeByte('\n');
    }

    pub fn eval(vm: *VM, expr: []const u8) !Value {
        return cx(vm).eval(expr);
    }
};

const Token = union(enum) {
    ident: []const u8,
    number: f64, // TODO: keep it []const u8?
    lparen,
    rparen,
};

const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    fn next(self: *Tokenizer) ?Token {
        if (self.pos >= self.input.len) return null;
        const ch: u8 = self.input[self.pos];
        self.pos += 1;

        return switch (ch) {
            '0'...'9' => .{ .number = std.fmt.parseFloat(f64, self.input) catch @panic("TODO") },
            else => @panic("TODO"),
        };
    }
};

fn expectEval(js: *Context, expr: []const u8, expected: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const res = try js.eval(expr);
    try js.print(buf.writer().any(), res);

    return std.testing.expectEqualStrings(expected, buf.items);
}

test {
    var js = try Context.init(std.testing.allocator);
    defer js.deinit();

    // const add = js.vm.get("+");
    // const res = try js.vm.call(add, &.{ Value.from(1), Value.from(2) });
    try js.vm.push(Value.from(1));
    try js.vm.push(Value.from(2));
    const res = try js.vm.call("+");

    try std.testing.expectEqual(3.0, res.number);

    const res2 = try js.eval("123");
    try std.testing.expectEqual(123.0, res2.number);

    // try expectEval(&js, "", "undefined");
    // try expectEval(&js, "null", "null");
    // try expectEval(&js, "true", "true");
    try expectEval(&js, "1", "1");
    try expectEval(&js, "1.2", "1.2");
    // try expectEval(&js, "\"foo\"", "\"foo\"");
}
