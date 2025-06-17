const builtin = @import("builtin");
const std = @import("std");
const Buf = @import("util.zig").Buf;

// https://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html
// https://swtch.com/~rsc/regexp/regexp1.html
// https://swtch.com/~rsc/regexp/regexp2.html
// https://swtch.com/~rsc/regexp/regexp3.html
pub const Regex = struct {
    code: []const Op,
    threads: []Thread,

    pub fn compile(allocator: std.mem.Allocator, regex: []const u8) !Regex {
        var tokenizer: Tokenizer = .{ .input = regex };
        const len, const depth = try countAndValidate(&tokenizer);

        const threads = try allocator.alloc(Thread, len * 2);
        errdefer allocator.free(threads);

        var code: Buf(Op) = try .initAlloc(allocator, len);
        errdefer code.deinit(allocator);

        var stack: Buf([2]i32) = try .initAlloc(allocator, depth);
        defer stack.deinit(allocator);

        var prev_atom: i32 = 0;
        var hole_other_branch: i32 = -1;

        while (tokenizer.next()) |tok| {
            const end: i32 = @intCast(code.len);

            switch (tok) {
                .char => |ch| {
                    prev_atom = end;
                    code.push(.char);
                    code.push(encode(ch));
                },

                .dot => {
                    code.push(.any);
                    prev_atom = end;
                },

                .que => {
                    code.insertSlice(@intCast(prev_atom), &.{
                        .split,
                        encode(2), // run the check
                        encode(end - prev_atom + 1), // jump out otherwise
                    });
                },

                .plus => {
                    code.push(.split);
                    code.push(encode(prev_atom - end - 1)); // repeat
                    code.push(encode(1)); // jump out otherwise
                },

                .star => {
                    code.insertSlice(@intCast(prev_atom), &.{
                        .split,
                        encode(2), // run the check
                        encode(end - prev_atom + 3), // jump out otherwise
                    });

                    code.push(.jmp);
                    code.push(encode(prev_atom - end - 4)); // keep repeating
                },

                .pipe => {
                    // TODO: groups? can we just put it in the stack?
                    code.insertSlice(@intCast(prev_atom), &.{
                        .split,
                        encode(2), // LHS branch (which ends with holey-jmp)
                        encode(end - prev_atom + 3), // RHS
                    });

                    // Point any previous hole to our newly created holey-jmp (double-jump)
                    // NOTE: we could probably inline/flatten these in a second-pass (optimization?)
                    if (hole_other_branch > 0) {
                        code.buf[@intCast(hole_other_branch)] = encode(@as(i32, @intCast(code.len)) - hole_other_branch); // relative to the jmp itself
                    }

                    // Create a jump with a hole
                    code.push(.jmp);
                    hole_other_branch = @intCast(code.len);
                    code.push(encode(if (comptime builtin.is_test) 0x7FFFFFFF else 1)); // so it blows if we don't fill it
                },

                .lparen => {
                    stack.push(.{ end, hole_other_branch });
                    prev_atom = end;
                    hole_other_branch = -1;
                },

                .rparen => {
                    if (hole_other_branch > 0) {
                        code.buf[@intCast(hole_other_branch)] = encode(end - hole_other_branch); // relative to the jmp itself
                    }

                    const x = stack.pop().?;
                    prev_atom = x[0];
                    hole_other_branch = x[1];
                },

                .caret => code.push(.begin),
                .dollar => code.push(.end),
            }
        }

        // Pending pipe?
        if (hole_other_branch > 0) {
            const end: i32 = @intCast(code.len);
            code.buf[@intCast(hole_other_branch)] = encode(end - hole_other_branch); // relative to the jmp itself
        }

        // Add final match
        code.push(.match);

        return .{
            .code = code.finish(),
            .threads = threads,
        };
    }

    pub fn deinit(self: *Regex, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.threads);
    }

    pub fn match(self: *Regex, text: []const u8) bool {
        return pikevm(self.code, text, self.threads);
    }

    fn countAndValidate(tokenizer: *Tokenizer) ![2]usize {
        var len: usize = 1; // we always append match
        var depth: usize = 0; // current grouping level
        var max_depth: usize = 0; // stack size we need for compilation
        var can_repeat: bool = false; // repeating & empty groups

        while (tokenizer.next()) |tok| {
            if (!can_repeat) switch (tok) {
                .que, .plus, .star => return error.NothingToRepeat,
                else => {},
            };

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
                .dot, .dollar, .caret => len += 1,
                .char => len += 2,
                .que, .plus => len += 3,
                .star, .pipe => len += 5,
            }

            can_repeat = switch (tok) {
                .char, .dot, .rparen => true,
                else => false,
            };
        }

        if (depth > 0) {
            return error.UnclosedGroup;
        }

        tokenizer.pos = 0; // reset back
        return .{ len, max_depth };
    }
};

const Token = union(enum) {
    char: u8,
    dot,
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
        // TODO: escaping (\\ -> char, \+ -> char, but \w -> alphanum)
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            self.pos += 1;

            return switch (ch) {
                '.' => .dot,
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

// TODO: would be nice if we could avoid i32, but we perform code-insertions
//       which can make already created absolute jumps invalid
//       we could either fix them just-in-time, or we could simply emit
//       @bitCast() relative jumps and then, resolve them in a second-pass,
//       which should be there anyway, so we can get rid of those mid-jumps.
const Op = enum(i32) {
    begin,
    end,
    char, // u8
    any,
    match,
    jmp, // i32
    split, // i32, i32
    _,

    fn name(self: Op) []const u8 {
        return switch (self) {
            .begin, .end, .char, .any, .match, .jmp, .split => @tagName(self),
            else => "???",
        };
    }
};

const Thread = struct {
    pc: usize,
};

fn encode(v: i32) Op {
    return @enumFromInt(@as(i32, @intCast(v)));
}

fn decode(code: []const Op, pc: usize) i32 {
    return @intFromEnum(code[pc]);
}

fn decodeJmp(code: []const Op, pc: usize) usize {
    return @intCast(@as(isize, @intCast(pc)) + decode(code, pc));
}

// https://dl.acm.org/doi/10.1145/363347.363387
// https://swtch.com/~rsc/regexp/regexp2.html#pike
// TODO: captures
fn pikevm(code: []const Op, text: []const u8, threads: []Thread) bool {
    var clist = Buf(Thread).init(threads[0 .. threads.len / 2]);
    var nlist = Buf(Thread).init(threads[threads.len / 2 ..]);

    // Initial thread
    clist.push(.{ .pc = 0 });

    var sp: usize = 0;
    while (true) : (sp += 1) {
        // std.debug.print("sp={}\n", .{sp});

        // TODO: I think it can still overflow but maybe we could just compute real max size for clist/nlist in count()?
        var j: usize = 0; // ^/jmp/split needs to be processed before advancing
        while (j < clist.len) : (j += 1) { // and we do that by pushing to clist
            const pc = clist.buf[j].pc;

            switch (code[pc]) {
                .begin => if (sp == 0) clist.push(.{ .pc = pc + 1 }),
                .end => if (sp == text.len) clist.push(.{ .pc = pc + 1 }), // TODO (the other version does not work yet either)
                .char => if (sp < text.len and text[sp] == decode(code, pc + 1)) nlist.push(.{ .pc = pc + 2 }),
                .any => if (sp < text.len) nlist.push(.{ .pc = pc + 1 }),
                .jmp => clist.push(.{ .pc = decodeJmp(code, pc + 1) }),
                .split => {
                    clist.push(.{ .pc = decodeJmp(code, pc + 1) });
                    clist.push(.{ .pc = decodeJmp(code, pc + 2) });
                },
                .match => return true,
                else => return false,
            }
        }

        if (sp == text.len) break;
        std.mem.swap(Buf(Thread), &clist, &nlist);
        nlist.len = 0;
    }

    return false;
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

        pc += switch (op) {
            .split => 3,
            .char, .jmp => 2,
            else => 1,
        };
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

    try expectCompile("", "  0: match");

    try expectCompile("abc",
        \\  0: char a
        \\  2: char b
        \\  4: char c
        \\  6: match
    );

    try expectCompile("a.c",
        \\  0: char a
        \\  2: any
        \\  3: char c
        \\  5: match
    );

    try expectCompile("a?c",
        \\  0: split :3 :5
        \\  3: char a
        \\  5: char c
        \\  7: match
    );

    try expectCompile("ab?c",
        \\  0: char a
        \\  2: split :5 :7
        \\  5: char b
        \\  7: char c
        \\  9: match
    );

    try expectCompile("a+b",
        \\  0: char a
        \\  2: split :0 :5
        \\  5: char b
        \\  7: match
    );

    try expectCompile("a*b",
        \\  0: split :3 :7
        \\  3: char a
        \\  5: jmp :0
        \\  7: char b
        \\  9: match
    );

    try expectCompile("a|b",
        \\  0: split :3 :7
        \\  3: char a
        \\  5: jmp :9
        \\  7: char b
        \\  9: match
    );

    try expectCompile("ab|c",
        \\  0: char a
        \\  2: split :5 :9
        \\  5: char b
        \\  7: jmp :11
        \\  9: char c
        \\ 11: match
    );

    try expectCompile("a|b|c",
        \\  0: split :3 :7
        \\  3: char a
        \\  5: jmp :12
        \\  7: split :10 :14
        \\ 10: char b
        \\ 12: jmp :16
        \\ 14: char c
        \\ 16: match
    );

    try expectCompile("(ab)?de",
        \\  0: split :3 :7
        \\  3: char a
        \\  5: char b
        \\  7: char d
        \\  9: char e
        \\ 11: match
    );

    try expectCompile("(ab)+de",
        \\  0: char a
        \\  2: char b
        \\  4: split :0 :7
        \\  7: char d
        \\  9: char e
        \\ 11: match
    );

    try expectCompile("(a|b)?",
        \\  0: split :3 :12
        \\  3: split :6 :10
        \\  6: char a
        \\  8: jmp :12
        \\ 10: char b
        \\ 12: match
    );

    try expectCompile("(a|b)*c",
        \\  0: split :3 :14
        \\  3: split :6 :10
        \\  6: char a
        \\  8: jmp :12
        \\ 10: char b
        \\ 12: jmp :0
        \\ 14: char c
        \\ 16: match
    );

    try expectCompile("(a|b|c)+d",
        \\  0: split :3 :7
        \\  3: char a
        \\  5: jmp :12
        \\  7: split :10 :14
        \\ 10: char b
        \\ 12: jmp :16
        \\ 14: char c
        \\ 16: split :0 :19
        \\ 19: char d
        \\ 21: match
    );

    try expectCompile("a(b|c)+",
        \\  0: char a
        \\  2: split :5 :9
        \\  5: char b
        \\  7: jmp :11
        \\  9: char c
        \\ 11: split :2 :14
        \\ 14: match
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
        .{ "c", false },
        .{ "d", false },
    });

    // Group
    try expectMatches("(abc)?def", &.{
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
        // .{ "hello world", true },
        // .{ "world peace", false },
    });

    // Empty
    try expectMatch("hello", "", false);
    try expectMatch(".*", "", true);
    try expectMatch("", "", true);
    try expectMatch("", "any", true);

    // Combination
    // try expectMatches("^a.*b$", &.{
    //     .{ "ab", true },
    //     .{ "axxxb", true },
    //     .{ "axxx", false },
    // });
}
