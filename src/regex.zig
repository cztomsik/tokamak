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
        var tokenizer: Tokenizer = .{ .input = regex };
        const len, const depth = try countAndValidate(&tokenizer);

        // TODO: we should first attempt to optimize the regex before failing.
        if (len > 64) return error.RegexTooComplex;

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
        };
    }

    pub fn deinit(self: *Regex, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
    }

    pub fn match(self: *Regex, text: []const u8) bool {
        return pikevm(self.code, text);
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
                .char, .dot, .rparen, .que, .plus, .star => true,
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
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            self.pos += 1;

            // TODO: This is incomplete, \d and \w should be parsed as meta-classes, etc.
            if (ch == '\\' and self.pos < self.input.len) {
                const next_ch = self.input[self.pos];
                self.pos += 1;
                return .{ .char = next_ch };
            }

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

fn encode(v: i32) Op {
    return @enumFromInt(@as(i32, @intCast(v)));
}

fn decode(code: []const Op, pc: usize) i32 {
    return @intFromEnum(code[pc]);
}

fn decodeJmp(code: []const Op, pc: usize) usize {
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
                .char => {
                    if (sp < text.len and text[sp] == decode(code, pc + 1))
                        nlist |= maskPc(pc + 2);
                },
                .any => {
                    if (sp < text.len) nlist |= maskPc(pc + 1);
                },
                .jmp => {
                    clist |= maskPc(decodeJmp(code, pc + 1));
                },
                .split => {
                    clist |= maskPc(decodeJmp(code, pc + 1));
                    clist |= maskPc(decodeJmp(code, pc + 2));
                },
                .match => return true,
                else => return false,
            }
        }

        if (sp == text.len) break;
        clist = nlist;
        nlist = 0;
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
    try expectTokens("\\.+\\+\\\\", &.{ .char, .plus, .char, .char });
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
