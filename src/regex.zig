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
// https://swtch.com/~rsc/regexp/regexp1.html
// https://swtch.com/~rsc/regexp/regexp2.html
// https://swtch.com/~rsc/regexp/regexp3.html
pub const Regex = struct {
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
    code: Buf(Op),
    stack: Buf([2]i32),
    anchored: bool,
    start: i32 = 0, // TODO: groups?
    prev_atom: i32 = 0,
    hole_other_branch: i32 = -1,

    fn init(allocator: std.mem.Allocator, regex: []const u8) !Compiler {
        var tokenizer: Tokenizer = .{ .input = regex };
        const len, const depth, const anchored = try countAndValidate(&tokenizer);

        var code: Buf(Op) = try .initAlloc(allocator, len);
        errdefer code.deinit(allocator);

        var stack: Buf([2]i32) = try .initAlloc(allocator, depth);
        errdefer stack.deinit(allocator);

        if (len > 64) {
            // TODO: we should first attempt to optimize the regex before failing.
            return error.RegexTooComplex;
        }

        return .{
            .allocator = allocator,
            .tokenizer = tokenizer,
            .code = code,
            .stack = stack,
            .anchored = anchored,
        };
    }

    fn deinit(self: *Compiler) void {
        self.code.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    fn compile(self: *Compiler) !void {
        // Implicit .dotstar for unanchored patterns
        if (!self.anchored) {
            self.emit(.dotstar);
            self.start = 1;
        }

        while (self.tokenizer.next()) |tok| {
            const end: i32 = @intCast(self.code.len);

            switch (tok) {
                .char => |ch| {
                    self.prev_atom = end;
                    self.emit(.char);
                    self.emit(encode(ch));
                },

                inline else => |_, t| {
                    self.prev_atom = end;
                    self.emit(@field(Op, @tagName(t)));
                },

                .que => {
                    self.code.insertSlice(@intCast(self.prev_atom), &.{
                        .isplit,
                        encode(2), // run the check
                        encode(end - self.prev_atom + 1), // jump out otherwise
                    });
                },

                .plus => {
                    self.emit(.isplit);
                    self.emit(encode(self.prev_atom - end - 1)); // repeat
                    self.emit(encode(1)); // jump out otherwise
                },

                .star => {
                    self.code.insertSlice(@intCast(self.prev_atom), &.{
                        .isplit,
                        encode(2), // run the check
                        encode(end - self.prev_atom + 3), // jump out otherwise
                    });

                    self.emit(.ijmp);
                    self.emit(encode(self.prev_atom - end - 4)); // keep repeating
                },

                .pipe => {
                    self.code.insertSlice(@intCast(self.start), &.{
                        .isplit,
                        encode(2), // LHS branch (which ends with holey-jmp)
                        encode(end - self.start + 3), // RHS
                    });

                    // Point any previous hole to our newly created holey-jmp (double-jump)
                    // NOTE: we could probably inline/flatten these in a second-pass (optimization?)
                    if (self.hole_other_branch > 0) {
                        self.code.buf[@intCast(self.hole_other_branch)] = encode(@as(i32, @intCast(self.code.len)) - self.hole_other_branch); // relative to the jmp itself
                    }

                    // Create a jump with a hole
                    self.emit(.ijmp);
                    self.hole_other_branch = @intCast(self.code.len);
                    self.emit(encode(if (comptime builtin.is_test) 0x7FFFFFFF else 1)); // so it blows if we don't fill it

                    // TODO: Is this correct?
                    self.start = @intCast(self.code.len);
                },

                .lparen => {
                    self.stack.push(.{ end, self.hole_other_branch });
                    self.prev_atom = end;
                    self.hole_other_branch = -1;

                    // TODO: Is this correct?
                    self.start = @intCast(self.code.len);
                },

                .rparen => {
                    if (self.hole_other_branch > 0) {
                        self.code.buf[@intCast(self.hole_other_branch)] = encode(end - self.hole_other_branch); // relative to the jmp itself
                    }

                    const x = self.stack.pop().?;
                    self.prev_atom = x[0];
                    self.hole_other_branch = x[1];
                },

                .caret => self.emit(.begin),
                .dollar => self.emit(.end),
            }
        }

        // Pending pipe?
        if (self.hole_other_branch > 0) {
            const end: i32 = @intCast(self.code.len);
            self.code.buf[@intCast(self.hole_other_branch)] = encode(end - self.hole_other_branch); // relative to the jmp itself
        }

        // Add final match
        self.emit(.match);
    }

    fn optimize(self: *Compiler) void {
        const code = self.code.buf[0..self.code.len];
        var pc: usize = 0;

        while (pc < code.len) : (pc += code[pc].len()) {
            switch (code[pc]) {
                // ijmp -> jmp
                .ijmp => {
                    code[pc] = .jmp;
                    code[pc + 1] = encode(decodeRelJmp(code, pc + 1));
                },

                // isplit -> split
                .isplit => {
                    code[pc] = .split;
                    code[pc + 1] = encode(decodeRelJmp(code, pc + 1));
                    code[pc + 2] = encode(decodeRelJmp(code, pc + 2));
                },

                else => {},
            }
        }
    }

    fn emit(self: *Compiler, op: Op) void {
        self.code.push(op);
    }

    fn finish(self: *Compiler) ![]const Op {
        return self.code.finish();
    }

    fn countAndValidate(tokenizer: *Tokenizer) !struct { usize, usize, bool } {
        var len: usize = 1; // we always append match
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
                    if (depth == 0) return error.NothingToClose;
                    if (!can_repeat) return error.EmptyGroup;
                    depth -= 1;
                },
                .dot, .dotstar, .word, .non_word, .digit, .non_digit, .space, .non_space, .dollar, .caret => len += 1,
                .char => len += 2,
                .que, .plus => len += 3,
                .star, .pipe => len += 5,
            }

            can_repeat = switch (tok) {
                .char, .dot, .dotstar, .rparen, .que, .plus, .star, .word, .non_word, .digit, .non_digit, .space, .non_space => true,
                else => false,
            };
        }

        if (depth > 0) {
            return error.UnclosedGroup;
        }

        if (!anchored) {
            len += 1; // Implicit .dotstar at the beginning
        }

        // Reset and return
        tokenizer.pos = 0;
        return .{ len, max_depth, anchored };
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
    dollar,
    caret,
};

const Tokenizer = struct {
    input: []const u8,
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
                '^' => .caret,
                '$' => .dollar,
                else => .{ .char = ch },
            };
        }

        return null;
    }
};

const Op = enum(i32) {
    begin,
    end,
    char, // u8
    dot,
    dotstar,
    word,
    non_word,
    digit,
    non_digit,
    space,
    non_space,
    match,
    jmp, // u32
    split, // u32, u32

    // intermediate - replaced during optimize()
    ijmp, // i32
    isplit, // i32, i32
    _,

    fn name(self: Op) []const u8 {
        return switch (self) {
            .begin, .end, .char, .dot, .dotstar, .word, .non_word, .digit, .non_digit, .space, .non_space, .match, .jmp, .split => @tagName(self),
            else => "???",
        };
    }

    fn len(self: Op) usize {
        return switch (self) {
            .split, .isplit => 3,
            .char, .jmp, .ijmp => 2,
            else => 1,
        };
    }
};

fn encode(v: anytype) Op {
    return @enumFromInt(@as(i32, @intCast(v)));
}

fn decode(code: []const Op, pc: usize) i32 {
    return @intFromEnum(code[pc]);
}

fn decodeJmp(code: []const Op, pc: usize) usize {
    return @intCast(decode(code, pc));
}

fn decodeRelJmp(code: []const Op, pc: usize) usize {
    return @intCast(@as(isize, @intCast(pc)) + decode(code, pc));
}

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

            switch (code[pc]) {
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
                .char => {
                    if (sp < text.len and text[sp] == decode(code, pc + 1))
                        nlist |= maskPc(pc + 2);
                },
                .dot => {
                    if (sp < text.len) nlist |= maskPc(pc + 1);
                },
                .word => {
                    if (sp < text.len and isWord(text[sp])) nlist |= maskPc(pc + 1);
                },
                .non_word => {
                    if (sp < text.len and !isWord(text[sp])) nlist |= maskPc(pc + 1);
                },
                .digit => {
                    if (sp < text.len and std.ascii.isDigit(text[sp])) nlist |= maskPc(pc + 1);
                },
                .non_digit => {
                    if (sp < text.len and !std.ascii.isDigit(text[sp])) nlist |= maskPc(pc + 1);
                },
                .space => {
                    if (sp < text.len and std.ascii.isWhitespace(text[sp])) nlist |= maskPc(pc + 1);
                },
                .non_space => {
                    if (sp < text.len and !std.ascii.isWhitespace(text[sp])) nlist |= maskPc(pc + 1);
                },
                .jmp => {
                    clist |= maskPc(decodeJmp(code, pc + 1));
                },
                .split => {
                    clist |= maskPc(decodeJmp(code, pc + 1));
                    clist |= maskPc(decodeJmp(code, pc + 2));
                },
                .match => return true,
                .ijmp, .isplit => unreachable,
                else => return false,
            }
        }

        if (sp == text.len) break;
        clist = nlist;
        nlist = 0;
    }

    return false;
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
}

fn expectCompile(regex: []const u8, expected: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    var w = buf.writer();
    defer buf.deinit();

    var re = try Regex.compile(std.testing.allocator, regex);
    defer re.deinit(std.testing.allocator);

    var pc: usize = 0;

    while (pc < re.code.len) {
        const op = re.code[pc];

        if (pc > 0) {
            try w.writeByte('\n');
        }

        try w.print("{d:>3}: {s}", .{ pc, op.name() });

        switch (op) {
            .char => try w.print(" {c}", .{
                @as(u8, @intCast(decode(re.code, pc + 1))),
            }),
            .jmp => try w.print(" :{d}", .{
                decodeJmp(re.code, pc + 1),
            }),
            .split => try w.print(" :{d} :{d}", .{
                decodeJmp(re.code, pc + 1),
                decodeJmp(re.code, pc + 2),
            }),
            else => {},
        }

        pc += op.len();
    }

    try std.testing.expectEqualStrings(expected, buf.items);
}

test "Regex.compile()" {
    try testing.expectError(Regex.compile(undefined, "?"), error.NothingToRepeat);
    try testing.expectError(Regex.compile(undefined, "+"), error.NothingToRepeat);
    try testing.expectError(Regex.compile(undefined, "*"), error.NothingToRepeat);
    try testing.expectError(Regex.compile(undefined, "()"), error.EmptyGroup);
    try testing.expectError(Regex.compile(undefined, ")"), error.NothingToClose);
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
        \\  3: char b
        \\  5: char c
        \\  7: match
    );

    try expectCompile("a.c",
        \\  0: dotstar
        \\  1: char a
        \\  3: dot
        \\  4: char c
        \\  6: match
    );

    try expectCompile("a?c",
        \\  0: dotstar
        \\  1: split :4 :6
        \\  4: char a
        \\  6: char c
        \\  8: match
    );

    try expectCompile("ab?c",
        \\  0: dotstar
        \\  1: char a
        \\  3: split :6 :8
        \\  6: char b
        \\  8: char c
        \\ 10: match
    );

    try expectCompile("a+b",
        \\  0: dotstar
        \\  1: char a
        \\  3: split :1 :6
        \\  6: char b
        \\  8: match
    );

    try expectCompile("a*b",
        \\  0: dotstar
        \\  1: split :4 :8
        \\  4: char a
        \\  6: jmp :1
        \\  8: char b
        \\ 10: match
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
        \\  1: split :4 :8
        \\  4: char a
        \\  6: jmp :10
        \\  8: char b
        \\ 10: match
    );

    try expectCompile("ab|c",
        \\  0: dotstar
        \\  1: split :4 :10
        \\  4: char a
        \\  6: char b
        \\  8: jmp :12
        \\ 10: char c
        \\ 12: match
    );

    try expectCompile("a|b|c",
        \\  0: dotstar
        \\  1: split :4 :8
        \\  4: char a
        \\  6: jmp :13
        \\  8: split :11 :15
        \\ 11: char b
        \\ 13: jmp :17
        \\ 15: char c
        \\ 17: match
    );

    try expectCompile("(ab)?de",
        \\  0: dotstar
        \\  1: split :4 :8
        \\  4: char a
        \\  6: char b
        \\  8: char d
        \\ 10: char e
        \\ 12: match
    );

    try expectCompile("(ab)+de",
        \\  0: dotstar
        \\  1: char a
        \\  3: char b
        \\  5: split :1 :8
        \\  8: char d
        \\ 10: char e
        \\ 12: match
    );

    try expectCompile("(a|b)?",
        \\  0: dotstar
        \\  1: split :4 :13
        \\  4: split :7 :11
        \\  7: char a
        \\  9: jmp :13
        \\ 11: char b
        \\ 13: match
    );

    try expectCompile("(a|b)*c",
        \\  0: dotstar
        \\  1: split :4 :15
        \\  4: split :7 :11
        \\  7: char a
        \\  9: jmp :13
        \\ 11: char b
        \\ 13: jmp :1
        \\ 15: char c
        \\ 17: match
    );

    try expectCompile("(a|b|c)+d",
        \\  0: dotstar
        \\  1: split :4 :8
        \\  4: char a
        \\  6: jmp :13
        \\  8: split :11 :15
        \\ 11: char b
        \\ 13: jmp :17
        \\ 15: char c
        \\ 17: split :1 :20
        \\ 20: char d
        \\ 22: match
    );

    try expectCompile("a(b|c)+",
        \\  0: dotstar
        \\  1: char a
        \\  3: split :6 :10
        \\  6: char b
        \\  8: jmp :12
        \\ 10: char c
        \\ 12: split :3 :15
        \\ 15: match
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
