// Tiny, JS-like execution context.

const std = @import("std");
const meta = @import("meta.zig");
const util = @import("util.zig");
const VM = @import("vm.zig").VM;
const Value = @import("vm.zig").Value;
const Op = @import("vm.zig").Op;

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
        var arena = std.heap.ArenaAllocator.init(self.vm.gpa);
        defer arena.deinit();

        var parser = Parser.init(arena.allocator(), expr);
        const exp = try parser.parseExpr(0);

        const ops = try self.compile(arena.allocator(), exp);
        return self.vm.eval(ops);
    }

    fn compile(self: *Context, arena: std.mem.Allocator, expr: Expr) ![]const Op {
        // TODO: we should first compute the size and then do something like compileInto(&buf)
        //       and maybe even introduce Compiler? IDK but at least this works for now...
        var ops = std.array_list.Managed(Op).init(arena);

        switch (expr) {
            .atom => |tok| {
                const val = try tok.value(arena);
                try ops.append(.{ .push = val });
            },
            .cons => |cons| {
                if (cons.args.len != 2) return error.NotImplemented;

                const lhs_ops = try self.compile(arena, cons.args[0]);
                const rhs_ops = try self.compile(arena, cons.args[1]);

                try ops.appendSlice(lhs_ops);
                try ops.appendSlice(rhs_ops);

                // TODO: We need to do something about idents (pass them down?) and
                //       it's also likely that some of these should be VM ops
                const fun = switch (cons.op) {
                    .plus => "+",
                    .minus => "-",
                    .mul => "*",
                    .div => "/",
                    else => return error.NotImplemented,
                };

                try ops.append(.{ .call = .parse(fun) });
            },
        }

        return ops.toOwnedSlice();
    }

    pub fn print(self: *Context, writer: *std.io.Writer, val: Value) !void {
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
        var fw = std.fs.File.stderr().writer(&.{});
        const w = &fw.interface;
        try cx(vm).print(w, val);
        try w.writeByte('\n');
    }

    pub fn eval(vm: *VM, expr: []const u8) !Value {
        return cx(vm).eval(expr);
    }
};

// const Keyword = enum { undefined, null, true, false };

const Token = union(enum) {
    ident: []const u8,
    number: []const u8,
    // TODO: string: []const u8,

    // Operators
    dot,
    assign,
    plus,
    minus,
    mul,
    div,
    lparen,
    rparen,
    lbracket,
    rbracket,
    not,
    que,
    colon,

    fn value(self: Token, arena: std.mem.Allocator) !Value {
        // TODO: string dup
        _ = arena;

        return switch (self) {
            .number => |str| {
                const val = std.fmt.parseFloat(f64, str) catch return error.InvalidNumber;
                return Value.from(val);
            },
            else => error.NotAValue,
        };
    }
};

const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    fn next(self: *Tokenizer) ?Token {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            self.pos += 1;

            return switch (ch) {
                ' ', '\t', '\n', '\r' => continue,
                '0'...'9' => {
                    const start = self.pos - 1;
                    while (self.peek()) |d| : (self.pos += 1) if (!std.ascii.isDigit(d) and d != '.') break;
                    return .{ .number = self.input[start..self.pos] };
                },
                'a'...'z', 'A'...'Z', '_' => {
                    const start = self.pos - 1;
                    while (self.peek()) |c| : (self.pos += 1) if (!std.ascii.isAlphanumeric(c) and c != '_') break;

                    // TODO: if (std.meta.stringToEnum(Keyword, xxx)) return ???;
                    // I think we should return Token.xxx but then why have a Keyword enum in the first place?

                    return .{ .ident = self.input[start..self.pos] };
                },
                '+' => .plus,
                '-' => .minus,
                '*' => .mul,
                '/' => .div,
                '(' => .lparen,
                ')' => .rparen,
                '[' => .lbracket,
                ']' => .rbracket,
                '!' => .not,
                '=' => .assign,
                '?' => .que,
                ':' => .colon,
                '.' => .dot,
                else => @panic("TODO"),
            };
        }

        return null;
    }

    fn peek(self: *Tokenizer) ?u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }
};

const Expr = union(enum) {
    atom: Token,
    cons: struct {
        op: Token,
        args: []const Expr,
    },

    fn initCons(allocator: std.mem.Allocator, op: Token, args: []const Expr) !Expr {
        return .{
            .cons = .{
                .op = op,
                .args = try allocator.dupe(Expr, args),
            },
        };
    }

    pub fn format(self: Expr, writer: anytype) !void {
        switch (self) {
            .atom => |tok| {
                switch (tok) {
                    .number, .ident => |s| try writer.writeAll(s),
                    else => unreachable,
                }
            },
            .cons => |cons| {
                try writer.print("({s}", .{@tagName(cons.op)});
                for (cons.args) |arg| try writer.print(" {f}", .{arg});
                try writer.writeAll(")");
            },
        }
    }
};

// https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html
// https://martin.janiczek.cz/2023/07/03/demystifying-pratt-parsers.html
// https://www.crockford.com/javascript/tdop/tdop.html
const Parser = struct {
    arena: std.mem.Allocator,
    tokenizer: Tokenizer,
    pending: ?Token = null,

    fn init(arena: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .arena = arena,
            .tokenizer = .{ .input = input },
        };
    }

    fn peek(self: *Parser) ?Token {
        if (self.pending) |tok| return tok;
        self.pending = self.tokenizer.next();
        return self.pending;
    }

    fn next(self: *Parser) !Token {
        const tok = self.peek();
        self.pending = null;
        return tok orelse error.Eof;
    }

    fn parseExpr(self: *Parser, min_bp: u8) !Expr {
        var lhs: Expr = blk: {
            const tok = try self.next();

            switch (tok) {
                .number, .ident => break :blk .{ .atom = tok },
                .lparen => {
                    const res = try self.parseExpr(0);
                    const close = try self.next();
                    if (close != .rparen) return error.ExpectedRParen;
                    break :blk res;
                },
                .plus, .minus, .not => {
                    const rbp = prefixBp(tok);
                    const rhs = try self.parseExpr(rbp);
                    break :blk try Expr.initCons(self.arena, tok, &.{rhs});
                },
                else => return error.UnexpectedToken,
            }
        };

        while (true) {
            const tok = self.peek() orelse break;
            if (!isOperator(tok)) std.debug.panic("bad token: {s}", .{@tagName(tok)});

            if (postfixBp(tok)) |lbp| {
                if (lbp < min_bp) break;
                self.pending = null;

                if (tok == .lbracket) {
                    const rhs = try self.parseExpr(0);
                    const close = try self.next();
                    if (close != .rbracket) return error.ExpectedRBracket;
                    lhs = try Expr.initCons(self.arena, tok, &.{ lhs, rhs });
                }

                continue;
            }

            if (infixBp(tok)) |bp| {
                const lbp, const rbp = bp;
                if (lbp < min_bp) break;
                self.pending = null;

                if (tok == .que) {
                    const mhs = try self.parseExpr(0);
                    const colon = try self.next();
                    if (colon != .colon) return error.ExpectedColon;

                    const rhs = try self.parseExpr(rbp);
                    lhs = try Expr.initCons(self.arena, tok, &.{ lhs, mhs, rhs });
                } else {
                    const rhs = try self.parseExpr(rbp);
                    lhs = try Expr.initCons(self.arena, tok, &.{ lhs, rhs });
                }

                continue;
            }

            break;
        }

        return lhs;
    }

    fn isOperator(self: Token) bool {
        return switch (self) {
            .dot, .assign, .plus, .minus, .mul, .div, .lparen, .rparen, .lbracket, .rbracket, .not, .que, .colon => true,
            else => false,
        };
    }

    fn prefixBp(token: Token) u8 {
        return switch (token) {
            .plus, .minus, .not => 9,
            else => std.debug.panic("bad op: {s}", .{@tagName(token)}),
        };
    }

    fn postfixBp(token: Token) ?u8 {
        return switch (token) {
            .lbracket => 11,
            else => null,
        };
    }

    fn infixBp(token: Token) ?[2]u8 {
        return switch (token) {
            .assign => .{ 2, 1 },
            .que => .{ 4, 3 },
            .plus, .minus => .{ 5, 6 },
            .mul, .div => .{ 7, 8 },
            .dot => .{ 14, 13 },
            else => null,
        };
    }
};

fn expectParse(input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), input);
    const expr = try parser.parseExpr(0);

    return std.testing.expectFmt(expected, "{f}", .{expr});
}

test Parser {
    try expectParse("1", "1");
    try expectParse("1 + 2", "(plus 1 2)");
    try expectParse("1 + 2 * 3", "(plus 1 (mul 2 3))");
    try expectParse("(1 + 2) * 3", "(mul (plus 1 2) 3)");
    try expectParse("-1 + 2", "(plus (minus 1) 2)");
    try expectParse("!true", "(not true)");
    try expectParse("a.b.c", "(dot a (dot b c))");
    try expectParse("x[0][1]", "(lbracket (lbracket x 0) 1)");
    try expectParse("a ? b : c", "(que a b c)");
    try expectParse("x = 1 + 2", "(assign x (plus 1 2))");
}

fn expectEval(js: *Context, expr: []const u8, expected: []const u8) !void {
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    const res = try js.eval(expr);
    try js.print(&wb.writer, res);

    return std.testing.expectEqualStrings(expected, wb.written());
}

test Context {
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

    // TODO: empty
    // try expectEval(&js, "", "undefined");

    // TODO: keywords
    // try expectEval(&js, "null", "null");
    // try expectEval(&js, "true", "true");

    try expectEval(&js, "1", "1");
    try expectEval(&js, "1.2", "1.2");

    // TODO: strings
    // try expectEval(&js, "\"foo\"", "\"foo\"");

    try expectEval(&js, "1 + 2", "3");
    try expectEval(&js, "1 + 2 * 3", "7");

    // TODO: call expressions
    // try expectEval(&js, "print(1 + 2)", "undefined");
}
