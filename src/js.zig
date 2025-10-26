// Tiny, JS-like execution context.

const std = @import("std");
const meta = @import("meta.zig");
const util = @import("util.zig");
const vm = @import("vm.zig");
const Value = vm.Value;
const Op = vm.Op;

pub const Context = struct {
    vm: vm.Context,

    pub fn init(arena: std.mem.Allocator) !Context {
        var ctx = vm.Context.init(arena);

        inline for (comptime std.meta.declarations(Builtins)) |d| {
            try ctx.define(d.name, @field(Builtins, d.name));
        }

        return .{
            .vm = ctx,
        };
    }

    pub fn parent(self: *Context) ?*Context {
        if (self.vm.parent) |p| return cx(p);
        return null;
    }

    pub fn eval(self: *Context, expr: []const u8) !Value {
        var parser = Parser.init(self.vm.arena, expr);
        const exp = try parser.parseExpr(0);

        const ops = try self.compile(self.vm.arena, exp);
        return self.vm.eval(ops);
    }

    fn compile(self: *Context, arena: std.mem.Allocator, expr: Expr) ![]const Op {
        // TODO: we should first compute the size and then do something like compileInto(&buf)
        //       and maybe even introduce Compiler? IDK but at least this works for now...
        var ops = std.ArrayList(Op){};

        switch (expr) {
            .atom => |tok| {
                switch (tok) {
                    .ident => |name| {
                        try ops.append(arena, .{ .load = name });
                    },
                    else => {
                        const val = try tok.value(&self.vm);
                        try ops.append(arena, .{ .push = val });
                    },
                }
            },
            .cons => |cons| {
                if (cons.args.len != 2) return error.NotImplemented;

                if (cons.op == .dot or cons.op == .lbracket) {
                    const lhs_ops = try self.compile(arena, cons.args[0]);
                    try ops.appendSlice(arena, lhs_ops);

                    if (cons.op == .dot) {
                        const key = switch (cons.args[1]) {
                            .atom => |tok| switch (tok) {
                                .ident => |name| name,
                                else => return error.NotImplemented,
                            },
                            else => return error.NotImplemented,
                        };
                        try ops.append(arena, .{ .push = try self.vm.value(key) });
                    } else {
                        const rhs_ops = try self.compile(arena, cons.args[1]);
                        try ops.appendSlice(arena, rhs_ops);
                    }

                    try ops.append(arena, .get);
                    return ops.toOwnedSlice(arena);
                }

                const lhs_ops = try self.compile(arena, cons.args[0]);
                const rhs_ops = try self.compile(arena, cons.args[1]);

                try ops.appendSlice(arena, lhs_ops);
                try ops.appendSlice(arena, rhs_ops);

                // TODO: We need to do something about idents (pass them down?) and
                //       it's also likely that some of these should be VM ops

                // TODO: We also neeed to do something about the lifetime, maybe we could really just
                //       constraint the max len and keep all the idents inline?
                try ops.append(arena, .{ .load = switch (cons.op) {
                    .plus => "+",
                    .minus => "-",
                    .mul => "*",
                    .div => "/",
                    else => return error.NotImplemented,
                } });

                try ops.append(arena, .call);
            },
        }

        return ops.toOwnedSlice(arena);
    }

    pub fn print(self: *Context, writer: *std.io.Writer, val: Value) !void {
        _ = self; // autofix

        // TODO: It's likely that some of this will be js-specific.
        try writer.print("{f}", .{val});
    }
};

fn cx(vm_ctx: *vm.Context) *Context {
    return @fieldParentPtr("vm", vm_ctx);
}

const Builtins = struct {
    pub fn @"+"(ctx: *vm.Context, a: Value, b: Value) !Value {
        if (a == .number and b == .number) {
            return .{ .number = a.number + b.number };
        }

        if (a == .string or b == .string) {
            const res = try std.fmt.allocPrint(ctx.arena, "{f}{f}", .{ a, b });
            return .{ .string = res };
        }

        return error.TypeError;
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

    pub fn print(vm_ctx: *vm.Context, val: Value) !void {
        var fw = std.fs.File.stderr().writer(&.{});
        const w = &fw.interface;
        try cx(vm_ctx).print(w, val);
        try w.writeByte('\n');
    }

    pub fn eval(vm_ctx: *vm.Context, expr: []const u8) !Value {
        return cx(vm_ctx).eval(expr);
    }
};

// const Keyword = enum { undefined, null, true, false };

const Token = union(enum) {
    ident: []const u8,
    number: []const u8,
    string: []const u8,

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

    fn value(self: Token, ctx: *vm.Context) !Value {
        return switch (self) {
            .number => |str| {
                const val = std.fmt.parseFloat(f64, str) catch return error.InvalidNumber;
                return ctx.value(val);
            },
            .string => |str| {
                return ctx.value(str);
            },
            else => error.NotAValue,
        };
    }
};

const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    fn next(self: *Tokenizer) !?Token {
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

                // TODO: decode escapes, \x codepoints, template literals, etc. This is just a basic PoC!!!
                // BTW: Can't we just use std.json.* for decoding? Or at least for a while?
                '"', '\'' => {
                    const quote = ch;
                    const start = self.pos;

                    while (self.pos < self.input.len) {
                        const ch2 = self.input[self.pos];
                        if (ch2 == quote) {
                            const content = self.input[start..self.pos];
                            self.pos += 1;
                            return .{ .string = content };
                        }
                        if (ch2 == '\\' and self.pos + 1 < self.input.len) {
                            self.pos += 2;
                        } else {
                            self.pos += 1;
                        }
                    }

                    return error.UnterminatedString;
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
                    .string => |s| try writer.print("{f}", .{std.json.fmt(s, .{})}),
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

    fn peek(self: *Parser) !?Token {
        if (self.pending) |tok| return tok;
        self.pending = try self.tokenizer.next();
        return self.pending;
    }

    fn next(self: *Parser) !Token {
        const tok = try self.peek();
        self.pending = null;
        return tok orelse error.Eof;
    }

    fn parseExpr(self: *Parser, min_bp: u8) !Expr {
        var lhs: Expr = blk: {
            const tok = try self.next();

            switch (tok) {
                .number, .ident, .string => break :blk .{ .atom = tok },
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
            const tok = try self.peek() orelse break;
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

    try expectParse("\"hello\"", "\"hello\"");
    try expectParse("'hello'", "\"hello\"");
    try expectParse("\"hello\" + \"world\"", "(plus \"hello\" \"world\")");
    try expectParse("name + \" is \" + age", "(plus (plus name \" is \") age)");
}

fn expectEval(js: *Context, expr: []const u8, expected: []const u8) !void {
    var wb = std.io.Writer.Allocating.init(std.testing.allocator);
    defer wb.deinit();

    const res = try js.eval(expr);
    try js.print(&wb.writer, res);

    return std.testing.expectEqualStrings(expected, wb.written());
}

test Context {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var js = try Context.init(arena.allocator());

    // TODO: empty
    // try expectEval(&js, "", "undefined");

    // TODO: keywords
    // try expectEval(&js, "null", "null");
    // try expectEval(&js, "true", "true");

    // Literals
    try expectEval(&js, "1", "1");
    try expectEval(&js, "1.2", "1.2");

    // String literals
    try expectEval(&js, "\"hello\"", "hello");
    try expectEval(&js, "'hello'", "hello");

    // String concat
    try expectEval(&js, "\"hello\" + \" world\"", "hello world");
    try expectEval(&js, "\"Count: \" + 42", "Count: 42");
    try expectEval(&js, "5 + \" items\"", "5 items");

    try expectEval(&js, "1 + 2", "3");
    try expectEval(&js, "1 + 2 * 3", "7");

    // TODO: call expressions
    // try expectEval(&js, "print(1 + 2)", "undefined");

    // Vars
    try js.vm.define("x", 10);
    try expectEval(&js, "x", "10");
    try expectEval(&js, "x + 20", "30");

    // Property access
    try js.vm.define("user", .{ .name = "Alice", .age = 30 });
    try expectEval(&js, "user.name", "Alice");
    try expectEval(&js, "user.age", "30");

    // Array indexing
    try js.vm.define("items", &[_]f64{ 10, 20, 30 });
    try expectEval(&js, "items[0]", "10");
    try expectEval(&js, "items[1]", "20");
    try expectEval(&js, "items[2]", "30");

    // Combined operations
    try expectEval(&js, "items[0] + items[1]", "30");
    try expectEval(&js, "user.age + 10", "40");
}
