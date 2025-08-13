const builtin = @import("builtin");
const std = @import("std");
const Buf = @import("util.zig").Buf;

pub const Grep = struct {
    buf: []u8,
    reader: std.io.AnyReader,
    regex: *Regex,
    line: usize = 0,

    pub fn init(buf: []u8, reader: std.io.AnyReader, regex: *Regex) Grep {
        return .{
            .buf = buf,
            .reader = reader,
            .regex = regex,
        };
    }

    pub fn next(self: *Grep) ?[]const u8 {
        while (self.nextLine()) |line| {
            if (self.regex.match(line)) return line;
        } else return null;
    }

    fn nextLine(self: *Grep) ?[]const u8 {
        const line = (self.reader.readUntilDelimiterOrEof(self.buf, '\n') catch return null) orelse return null;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        self.line += 1;
        return trimmed;
    }
};

// https://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html
// https://dl.acm.org/doi/pdf/10.1145/363347.363387
// https://swtch.com/~rsc/regexp/regexp1.html
// https://swtch.com/~rsc/regexp/regexp2.html
// https://swtch.com/~rsc/regexp/regexp3.html
pub const Regex = struct {
    // [ops_main][...ops_clz]
    code: []const Op,

    pub fn compile(allocator: std.mem.Allocator, regex: []const u8) !Regex {
        var compiler = try Compiler.init(allocator, regex);
        defer compiler.deinit();

        try compiler.compile();
        compiler.optimize();

        return .{
            .code = try compiler.finish(),
        };
    }

    pub fn deinit(self: *Regex, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
    }

    pub fn match(self: *Regex, text: []const u8) bool {
        return pikevm(self.code, text);
    }
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    ops_main: Buf(Op),
    ops_clz: Buf(Op),
    stack: Buf([3]i8),
    anchored: bool,
    start: i8 = 0,
    atom: i8 = 0,
    hole: i8 = 0,
    clz_start: u8 = 0,

    const Info = struct {
        anchored: bool,
        depth: usize,
        n_main: usize,
        n_clz: usize,
    };

    fn init(allocator: std.mem.Allocator, regex: []const u8) !Compiler {
        var tokenizer: Tokenizer = .{ .input = regex };
        const info = try analyze(&tokenizer);

        const code = try allocator.alloc(Op, info.n_main + info.n_clz);
        errdefer allocator.free(code);

        var stack: Buf([3]i8) = try .initAlloc(allocator, info.depth);
        errdefer stack.deinit(allocator);

        if (info.n_main > 64) {
            // TODO: we should first attempt to optimize the regex before failing.
            return error.RegexTooComplex;
        }

        return .{
            .allocator = allocator,
            .tokenizer = tokenizer,
            .ops_main = .init(code[0..info.n_main]),
            .ops_clz = .init(code[info.n_main..]),
            .stack = stack,
            .anchored = info.anchored,
        };
    }

    fn deinit(self: *Compiler) void {
        self.allocator.free(self.ops_main.buf.ptr[0 .. self.ops_main.buf.len + self.ops_clz.buf.len]);
        self.stack.deinit(self.allocator);
    }

    fn compile(self: *Compiler) !void {
        // Implicit .dotstar for unanchored patterns
        if (!self.anchored) {
            self.push(.dotstar);
            self.start = 1;
        }

        while (self.tokenizer.next()) |tok| {
            const end: i8 = @intCast(self.ops_main.len);

            switch (tok) {
                inline else => |arg, t| {
                    if (!self.tokenizer.in_bracket) {
                        self.atom = end;
                    }

                    self.push(@unionInit(Op, @tagName(t), arg));
                },

                .que => {
                    self.insert(self.atom, .{
                        .isplit = .{
                            1, // run the check
                            end - self.atom + 1, // jump out otherwise
                        },
                    });
                },

                .plus => {
                    self.push(.{
                        .iplus = self.atom - end,
                    });
                },

                .star => {
                    self.insert(self.atom, .{
                        .isplit = .{
                            1, // run the check
                            end - self.atom + 2, // jump out otherwise
                        },
                    });

                    // Keep repeating
                    self.push(.{ .ijmp = self.atom - end - 1 });
                },

                .pipe => {
                    self.insert(self.start, .{
                        .isplit = .{
                            1, // LHS branch (which ends with holey-jmp)
                            end - self.start + 2, // RHS
                        },
                    });

                    // Point any previous hole to our newly created holey-jmp (double-jump)
                    // NOTE: we could probably inline/flatten these in a second-pass (optimization?)
                    if (self.hole > 0) {
                        self.ops_main.buf[@intCast(self.hole)].ijmp = @as(i8, @intCast(self.ops_main.len)) - self.hole;
                    }

                    // Create a jump with a hole
                    self.hole = @intCast(self.ops_main.len);
                    self.push(.{ .ijmp = if (comptime builtin.is_test) 0x7F else 1 }); // so it blows if we don't fill it
                    self.start = @intCast(self.ops_main.len);
                },

                .lparen => {
                    self.stack.push(.{ self.start, end, self.hole });

                    self.start = @intCast(self.ops_main.len);
                    self.atom = end;
                    self.hole = 0;
                },

                .rparen => {
                    if (self.hole > 0) {
                        self.ops_main.buf[@intCast(self.hole)].ijmp = end - self.hole;
                    }

                    const x = self.stack.pop().?;
                    self.start = x[0];
                    self.atom = x[1];
                    self.hole = x[2];
                },

                .lbracket => {
                    self.clz_start = @intCast(self.ops_main.buf.len + self.ops_clz.len);
                },

                .rbracket => {
                    self.atom = end;
                    self.push(.{ .char_class = .{ self.clz_start, @intCast(self.ops_main.buf.len + self.ops_clz.len) } });
                },

                .caret => self.push(.begin),
                .dollar => self.push(.end),
            }
        }

        // Pending pipe?
        if (self.hole > 0) {
            const end: i8 = @intCast(self.ops_main.len);
            self.ops_main.buf[@intCast(self.hole)].ijmp = end - self.hole;
        }

        // Add final match
        self.push(.match);
    }

    fn optimize(self: *Compiler) void {
        for (self.ops_main.buf[0..self.ops_main.len], 0..) |*op, pc| {
            const base: i8 = @intCast(pc);

            switch (op.*) {
                .ijmp => |off| op.* = .{ .jmp = @intCast(base + off) },

                .isplit => |offs| op.* = .{
                    .split = .{
                        @intCast(base + offs[0]),
                        @intCast(base + offs[1]),
                    },
                },

                .iplus => |off| op.* = .{ .plus = @intCast(base + off) },

                else => {},
            }
        }
    }

    fn push(self: *Compiler, op: Op) void {
        if (self.tokenizer.in_bracket) {
            self.ops_clz.push(op);
        } else {
            self.ops_main.push(op);
        }
    }

    fn insert(self: *Compiler, pos: i8, op: Op) void {
        std.debug.assert(!self.tokenizer.in_bracket);
        self.ops_main.insert(@intCast(pos), op);
    }

    fn finish(self: *Compiler) ![]const Op {
        // Save the ptr first bc. finish() would invalidate it
        const ptr = self.ops_main.buf.ptr;
        return ptr[0 .. self.ops_main.finish().len + self.ops_clz.finish().len];
    }

    fn analyze(tokenizer: *Tokenizer) !Info {
        var n_main: usize = 1; // we always append match
        var n_clz: usize = 0; // total count of ops inside brackets
        var depth: usize = 0; // current grouping level
        var max_depth: usize = 0; // stack size we need for compilation
        var can_repeat: bool = false; // repeating & empty groups
        var anchored: bool = false;

        while (tokenizer.next()) |tok| {
            if (!can_repeat) switch (tok) {
                .que, .plus, .star => return error.NothingToRepeat,
                else => {},
            };

            if (tok == .caret and depth == 0) anchored = true;
            if (tok == .pipe and depth == 0) anchored = false;

            switch (tok) {
                .lparen => {
                    depth += 1;
                    max_depth = @max(depth, max_depth);
                },
                .rparen => {
                    if (depth == 0) return error.NoGroupToClose;
                    if (!can_repeat) return error.EmptyGroup;
                    depth -= 1;
                },
                .lbracket => {
                    n_main += 1;
                },
                .rbracket => {},
                .pipe, .star => n_main += 2,
                else => {
                    if (tokenizer.in_bracket) {
                        n_clz += 1;
                    } else {
                        n_main += 1;
                    }
                },
            }

            can_repeat = switch (tok) {
                .char, .dot, .dotstar, .rparen, .rbracket, .que, .plus, .star, .word, .non_word, .digit, .non_digit, .space, .non_space => true,
                else => false,
            };
        }

        if (depth > 0) {
            return error.UnclosedGroup;
        }

        if (tokenizer.in_bracket) {
            return error.UnclosedBracket;
        }

        if (!anchored) {
            n_main += 1; // Implicit .dotstar at the beginning
        }

        // Reset and return
        tokenizer.pos = 0;

        return .{
            .n_main = n_main,
            .n_clz = n_clz,
            .depth = max_depth,
            .anchored = anchored,
        };
    }
};

const Token = union(enum) {
    char: u8,
    dot,
    dotstar,
    word,
    non_word,
    digit,
    non_digit,
    space,
    non_space,
    que,
    plus,
    star,
    pipe,
    lparen,
    rparen,
    lbracket,
    rbracket,
    dollar,
    caret,
};

const Tokenizer = struct {
    input: []const u8,
    in_bracket: bool = false,
    pos: usize = 0,

    fn next(self: *Tokenizer) ?Token {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            self.pos += 1;

            if (ch == '\\' and self.pos < self.input.len) {
                const next_ch = self.input[self.pos];
                self.pos += 1;

                return switch (next_ch) {
                    'w' => .word,
                    'W' => .non_word,
                    'd' => .digit,
                    'D' => .non_digit,
                    's' => .space,
                    'S' => .non_space,
                    else => .{ .char = next_ch },
                };
            }

            // TODO: ranges, ^, escapes?
            if (self.in_bracket) {
                return switch (ch) {
                    ']' => {
                        self.in_bracket = false;
                        return .rbracket;
                    },
                    else => .{ .char = ch },
                };
            }

            return switch (ch) {
                '.' => {
                    if (self.pos < self.input.len and self.input[self.pos] == '*') {
                        self.pos += 1;
                        return .dotstar;
                    }

                    return .dot;
                },
                '?' => .que,
                '+' => .plus,
                '*' => .star,
                '|' => .pipe,
                '(' => .lparen,
                ')' => .rparen,
                '[' => {
                    self.in_bracket = true;
                    return .lbracket;
                },
                ']' => .rbracket,
                '^' => .caret,
                '$' => .dollar,
                else => .{ .char = ch },
            };
        }

        return null;
    }
};

const Op = union(enum) {
    begin,
    end,

    // Char ops
    char: u8,
    dot,
    dotstar,
    word,
    non_word,
    digit,
    non_digit,
    space,
    non_space,

    // Char classes [\w_]
    char_class: [2]u8, // [start, end]

    // Branching
    jmp: u8,
    split: [2]u8,
    plus: u8,

    // Final op
    match,

    // Intermediate - replaced during optimize()
    ijmp: i8,
    isplit: [2]i8,
    iplus: i8,
    _,
};

fn maskPc(pc: usize) u64 {
    return @as(u64, 1) << @intCast(pc);
}

// https://dl.acm.org/doi/10.1145/363347.363387
// https://swtch.com/~rsc/regexp/regexp2.html#pike
// TODO: captures
fn pikevm(code: []const Op, text: []const u8) bool {
    // We only support N ops so we can actually encode both [N]Thread lists as
    // bitsets where each position represents the thread's PC. Even better, we
    // get de-duping and "same-char" ticks for free.
    var clist: u64 = 0;
    var nlist: u64 = 0;

    clist |= maskPc(0);

    var sp: usize = 0;
    while (true) : (sp += 1) {
        var guard: u64 = 0; // Which PCs we have already executed in this step

        while (clist != 0) {
            const pc = @ctz(clist); // Find the lowest bit
            clist &= clist - 1; // Clear that bit (we go backwards so we can do -1)

            // Guard against infinite recursion
            const mask = maskPc(pc);
            if ((guard & mask) != 0) continue;
            guard |= mask;

            const op = code[pc];

            switch (op) {
                .begin => {
                    if (sp == 0) clist |= maskPc(pc + 1);
                },
                .end => {
                    if (sp == text.len) clist |= maskPc(pc + 1);
                },
                .dotstar => {
                    clist |= maskPc(pc + 1);
                    if (sp < text.len) nlist |= maskPc(pc);
                },
                .char, .dot, .word, .non_word, .digit, .non_digit, .space, .non_space => {
                    if (sp < text.len and matchChar(op, text[sp])) nlist |= maskPc(pc + 1);
                },
                .char_class => |clz| {
                    if (sp < text.len and matchCharClass(code[clz[0]..clz[1]], text[sp])) nlist |= maskPc(pc + 1);
                },
                .jmp => |addr| {
                    clist |= maskPc(addr);
                },
                .split => |addrs| {
                    clist |= maskPc(addrs[0]);
                    clist |= maskPc(addrs[1]);
                },
                .plus => |addr| {
                    clist |= maskPc(addr);
                    clist |= maskPc(pc + 1);
                },
                .match => return true,
                .ijmp, .isplit, .iplus => unreachable,
                else => return false,
            }
        }

        if (sp == text.len) break;
        clist = nlist;
        nlist = 0;
    }

    return false;
}

fn matchChar(op: Op, ch: u8) bool {
    return switch (op) {
        .char => op.char == ch,
        .dot => true,
        .word => isWord(ch),
        .non_word => !isWord(ch),
        .digit => std.ascii.isDigit(ch),
        .non_digit => !std.ascii.isDigit(ch),
        .space => std.ascii.isWhitespace(ch),
        .non_space => !std.ascii.isWhitespace(ch),
        else => unreachable,
    };
}

fn matchCharClass(char_ops: []const Op, ch: u8) bool {
    for (char_ops) |op| {
        if (matchChar(op, ch)) return true;
    } else return false;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_';
}

const testing = @import("testing.zig");

fn expectTokens(regex: []const u8, tokens: []const std.meta.Tag(Token)) !void {
    var tokenizer = Tokenizer{ .input = regex };

    for (tokens) |tag| {
        const tok: @TypeOf(tag) = tokenizer.next() orelse return error.Eof;
        try testing.expectEqual(tok, tag);
    }

    try testing.expectEqual(tokenizer.pos, regex.len);
}

test Tokenizer {
    try expectTokens("", &.{});
    try expectTokens("a.c+", &.{ .char, .dot, .char, .plus });
    try expectTokens("a?(b|c)*", &.{ .char, .que, .lparen, .char, .pipe, .char, .rparen, .star });
    try expectTokens("\\.+\\+\\\\", &.{ .char, .plus, .char, .char });
    try expectTokens(".*\\w\\W\\d\\D+", &.{ .dotstar, .word, .non_word, .digit, .non_digit, .plus });
    try expectTokens("\\s\\S+", &.{ .space, .non_space, .plus });
    try expectTokens("[abc]", &.{ .lbracket, .char, .char, .char, .rbracket });
    try expectTokens("[ab.]", &.{ .lbracket, .char, .char, .char, .rbracket });
    try expectTokens("[\\w.]", &.{ .lbracket, .word, .char, .rbracket });
    // TODO: Fix this when we have ranges
    try expectTokens("[a-z]", &.{ .lbracket, .char, .char, .char, .rbracket });
}

fn expectCompile(regex: []const u8, expected: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    var w = buf.writer();
    defer buf.deinit();

    var re = try Regex.compile(std.testing.allocator, regex);
    defer re.deinit(std.testing.allocator);

    for (re.code, 0..) |op, pc| {
        if (pc > 0) {
            try w.writeByte('\n');
        }

        try w.print("{d:>3}: {s}", .{ pc, @tagName(op) });

        switch (op) {
            .char => |ch| try w.print(" {c}", .{ch}),
            .jmp => |addr| try w.print(" :{d}", .{addr}),
            .split => |addrs| try w.print(" :{d} :{d}", .{ addrs[0], addrs[1] }),
            .plus => |addr| try w.print(" :{d}", .{addr}),
            else => {},
        }
    }

    try std.testing.expectEqualStrings(expected, buf.items);
}

test "Regex.compile()" {
    try testing.expectError(Regex.compile(undefined, "?"), error.NothingToRepeat);
    try testing.expectError(Regex.compile(undefined, "+"), error.NothingToRepeat);
    try testing.expectError(Regex.compile(undefined, "*"), error.NothingToRepeat);
    try testing.expectError(Regex.compile(undefined, "()"), error.EmptyGroup);
    try testing.expectError(Regex.compile(undefined, ")"), error.NoGroupToClose);
    try testing.expectError(Regex.compile(undefined, "("), error.UnclosedGroup);

    try expectCompile("",
        \\  0: dotstar
        \\  1: match
    );

    try expectCompile(".",
        \\  0: dotstar
        \\  1: dot
        \\  2: match
    );

    try expectCompile("^.",
        \\  0: begin
        \\  1: dot
        \\  2: match
    );

    try expectCompile("abc",
        \\  0: dotstar
        \\  1: char a
        \\  2: char b
        \\  3: char c
        \\  4: match
    );

    try expectCompile("a.c",
        \\  0: dotstar
        \\  1: char a
        \\  2: dot
        \\  3: char c
        \\  4: match
    );

    try expectCompile("a?c",
        \\  0: dotstar
        \\  1: split :2 :3
        \\  2: char a
        \\  3: char c
        \\  4: match
    );

    try expectCompile("ab?c",
        \\  0: dotstar
        \\  1: char a
        \\  2: split :3 :4
        \\  3: char b
        \\  4: char c
        \\  5: match
    );

    try expectCompile("a+b",
        \\  0: dotstar
        \\  1: char a
        \\  2: plus :1
        \\  3: char b
        \\  4: match
    );

    try expectCompile("a*b",
        \\  0: dotstar
        \\  1: split :2 :4
        \\  2: char a
        \\  3: jmp :1
        \\  4: char b
        \\  5: match
    );

    // TODO: update anchor detection for leading .dotstar
    // try expectCompile(".*foo",
    //     \\  0: dotstar
    //     \\  1: char f
    //     \\  3: char o
    //     \\  5: char o
    //     \\  7: match
    // );

    try expectCompile("a|b",
        \\  0: dotstar
        \\  1: split :2 :4
        \\  2: char a
        \\  3: jmp :5
        \\  4: char b
        \\  5: match
    );

    try expectCompile("ab|c",
        \\  0: dotstar
        \\  1: split :2 :5
        \\  2: char a
        \\  3: char b
        \\  4: jmp :6
        \\  5: char c
        \\  6: match
    );

    try expectCompile("a|b|c",
        \\  0: dotstar
        \\  1: split :2 :4
        \\  2: char a
        \\  3: jmp :6
        \\  4: split :5 :7
        \\  5: char b
        \\  6: jmp :8
        \\  7: char c
        \\  8: match
    );

    try expectCompile("(ab)?de",
        \\  0: dotstar
        \\  1: split :2 :4
        \\  2: char a
        \\  3: char b
        \\  4: char d
        \\  5: char e
        \\  6: match
    );

    try expectCompile("(ab)+de",
        \\  0: dotstar
        \\  1: char a
        \\  2: char b
        \\  3: plus :1
        \\  4: char d
        \\  5: char e
        \\  6: match
    );

    try expectCompile("(a|b)?",
        \\  0: dotstar
        \\  1: split :2 :6
        \\  2: split :3 :5
        \\  3: char a
        \\  4: jmp :6
        \\  5: char b
        \\  6: match
    );

    try expectCompile("(a|b)*c",
        \\  0: dotstar
        \\  1: split :2 :7
        \\  2: split :3 :5
        \\  3: char a
        \\  4: jmp :6
        \\  5: char b
        \\  6: jmp :1
        \\  7: char c
        \\  8: match
    );

    try expectCompile("(a|b|c)+d",
        \\  0: dotstar
        \\  1: split :2 :4
        \\  2: char a
        \\  3: jmp :6
        \\  4: split :5 :7
        \\  5: char b
        \\  6: jmp :8
        \\  7: char c
        \\  8: plus :1
        \\  9: char d
        \\ 10: match
    );

    try expectCompile("a(b|c)+",
        \\  0: dotstar
        \\  1: char a
        \\  2: split :3 :5
        \\  3: char b
        \\  4: jmp :6
        \\  5: char c
        \\  6: plus :2
        \\  7: match
    );

    // TODO: No idea if this is correct but at least the jumps are valid.
    try expectCompile("^(\\w+\\.(js|ts)|^foo)",
        \\  0: begin
        \\  1: split :2 :12
        \\  2: word
        \\  3: plus :2
        \\  4: char .
        \\  5: split :6 :9
        \\  6: char j
        \\  7: char s
        \\  8: jmp :11
        \\  9: char t
        \\ 10: char s
        \\ 11: jmp :16
        \\ 12: begin
        \\ 13: char f
        \\ 14: char o
        \\ 15: char o
        \\ 16: match
    );
}

fn expectMatch(regex: []const u8, text: []const u8, expected: bool) !void {
    try expectMatches(regex, &.{.{ text, expected }});
}

fn expectMatches(regex: []const u8, fixtures: []const struct { []const u8, bool }) !void {
    var re = try Regex.compile(std.testing.allocator, regex);
    defer re.deinit(std.testing.allocator);

    for (fixtures) |fix| {
        errdefer std.debug.print("--- {s} --- {s}\n", .{ regex, fix[0] });

        try std.testing.expectEqual(fix[1], re.match(fix[0]));
    }
}

test "Regex.match()" {
    // Literal
    try expectMatches("hello", &.{
        .{ "hello", true },
        .{ "hello world", true },
        .{ "say hello", true },
        .{ "hi", false },
    });

    // Dot
    try expectMatches("h.llo", &.{
        .{ "hello", true },
        .{ "hallo", true },
        .{ "hllo", false },
    });

    // Question
    try expectMatches("ab?c", &.{
        .{ "ac", true },
        .{ "abc", true },
        .{ "abbc", false },
        .{ "adc", false },
    });

    // Plus
    try expectMatches("ab+c", &.{
        .{ "abc", true },
        .{ "abbc", true },
        .{ "ac", false },
    });

    // Star
    try expectMatches("ab*c", &.{
        .{ "ac", true },
        .{ "abc", true },
        .{ "abbc", true },
        .{ "adc", false },
    });

    // Pipe
    try expectMatches("a|b|c", &.{
        .{ "a", true },
        .{ "b", true },
        .{ "c", true },
        .{ "d", false },
    });

    try expectMatches("ab|c", &.{
        .{ "ab", true },
        .{ "ac", true },
        .{ "c", true },
        .{ "d", false },
    });

    // Group
    try expectMatches("^(abc)?def", &.{
        .{ "abcdef", true },
        .{ "def", true },
        .{ "adef", false },
    });

    try expectMatches("(ab)+de", &.{
        .{ "abde", true },
        .{ "ababde", true },
        .{ "abd", false },
    });

    try expectMatches("(ab)*de", &.{
        .{ "abde", true },
        .{ "ababde", true },
        .{ "de", true },
        .{ "abd", false },
    });

    try expectMatches("(a|b)*", &.{
        .{ "aba", true },
    });

    try expectMatches("(a|b)*c", &.{
        .{ "abbaabc", true },
        .{ "d", false },
    });

    // Start/End
    try expectMatches("^hello", &.{
        .{ "hello world", true },
        .{ "say hello", false },
    });

    try expectMatches("world$", &.{
        .{ "world", true },
        .{ "hello world", true },
        .{ "world peace", false },
    });

    // Empty
    try expectMatch("hello", "", false);
    try expectMatch(".*", "", true);
    try expectMatch("", "", true);
    try expectMatch("", "any", true);

    // Combination
    try expectMatches("^a.*b$", &.{
        .{ "ab", true },
        .{ "axxxb", true },
        .{ "axxx", false },
        .{ "baxxx", false },
    });

    // Escaping
    try expectMatches("\\.+", &.{
        .{ ".", true },
        .{ "..", true },
        .{ "a", false },
    });

    try expectMatches(".*/.*\\.txt", &.{
        .{ "/home/user/file.txt", true },
        .{ "dir/test.txt", true },
        .{ "file.pdf", false },
        .{ "filetxt", false },
    });

    try expectMatches("^[\\w_]+", &.{
        .{ "foo", true },
        .{ "foo_bar", true },
        .{ "@foo", false },
        .{ "", false },
    });
}

test "Something useful" {
    try expectMatches(".*@.*", &.{
        .{ "foo@bar.com", true },
        .{ "invalid", false },
    });

    try expectMatches(".*\\.js", &.{
        .{ "index.js", true },
        .{ "app.min.js", true },
        .{ "invalid", false },
    });

    try expectMatches("/api/.*", &.{
        .{ "/api/users", true },
        .{ "/api/users/123", true },
        .{ "invalid", false },
    });

    try expectMatches("^#+ .*", &.{
        .{ "# Heading 1", true },
        .{ "## Heading 2", true },
        .{ "#Invalid", false },
        .{ "Invalid", false },
    });
}
