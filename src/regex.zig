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
        const len, const depth = try countAndValidate(regex);

        const threads = try allocator.alloc(Thread, len * 2);
        errdefer allocator.free(threads);

        var code: Buf(Op) = try .initAlloc(allocator, len);
        errdefer code.deinit(allocator);

        var stack: Buf([2]i32) = try .initAlloc(allocator, depth);
        defer stack.deinit(allocator);

        var prev_atom: i32 = 0;
        var hole_other_branch: i32 = -1;

        for (regex) |ch| {
            const end: i32 = @intCast(code.len);

            switch (ch) {
                '^' => code.push(.begin),
                '$' => code.push(.begin),
                '(' => stack.push(.{ prev_atom, hole_other_branch }),
                ')' => {
                    if (hole_other_branch > 0) {
                        code.buf[@intCast(hole_other_branch)] = encode(end - hole_other_branch); // relative to the jmp itself
                    }

                    const x = stack.pop().?;
                    prev_atom = x[0];
                    hole_other_branch = x[1];
                },

                '?' => {
                    code.insertSlice(@intCast(prev_atom), &.{
                        .split,
                        encode(2), // run the check
                        encode(end - prev_atom + 1), // jump out otherwise
                    });
                },

                '+' => {
                    code.push(.split);
                    code.push(encode(prev_atom - end - 1)); // repeat
                    code.push(encode(1)); // jump out otherwise
                },

                '*' => {
                    code.insertSlice(@intCast(prev_atom), &.{
                        .split,
                        encode(2), // run the check
                        encode(end - prev_atom + 3), // jump out otherwise
                    });

                    code.push(.jmp);
                    code.push(encode(prev_atom - end - 4)); // keep repeating
                },

                '|' => {
                    // TODO: groups? can we just put it in the stack?
                    code.insertSlice(@intCast(hole_other_branch + 1), &.{
                        .split,
                        encode(2), // LHS branch (which ends with holey-jmp)
                        encode(end - hole_other_branch + 2), // RHS
                    });

                    // Point any previous hole to our newly created holey-jmp (double-jump)
                    // NOTE: we could probably inline/flatten these in a second-pass (optimization?)
                    if (hole_other_branch > 0) {
                        code.buf[@intCast(hole_other_branch)] = encode(@as(i32, @intCast(code.len)) - hole_other_branch); // relative to the jmp itself
                    }

                    // Create a jump with a hole
                    code.push(.jmp);
                    hole_other_branch = @intCast(code.len);
                    code.push(if (comptime builtin.is_test) encode(0x7FFFFFFF) else undefined); // so it blows if we don't fill this
                },

                '.' => {
                    code.push(.any);
                    prev_atom = end;
                },

                else => {
                    prev_atom = end;
                    code.push(.char);
                    code.push(encode(ch));
                },
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
        // TODO: implement & switch to pikevm(), or maybe only do that for longer texts?
        // return recursive(self.code.ptr, text, 0);

        return pikevm(self.code, text, self.threads);
    }

    // TODO: validate
    fn countAndValidate(regex: []const u8) ![2]usize {
        var len: usize = 1;
        var depth: usize = 0;

        for (regex) |ch| switch (ch) {
            '(' => depth += 1,
            ')' => {},
            '^', '$', '.' => len += 1,
            '?', '+' => len += 3,
            '*', '|' => len += 5,
            else => len += 2,
        };

        return .{ len, depth };
    }
};

const Op = enum(i32) {
    begin,
    end,
    char, // u8
    any,
    match,
    jmp, // i32
    split, // i32, i32
    _,
};

const Thread = struct {
    pc: [*]const Op,
};

fn encode(v: i32) Op {
    return @enumFromInt(@as(i32, @intCast(v)));
}

fn decode(pc: [*]const Op) i32 {
    return @intFromEnum(pc[0]);
}

fn decodeJmp(pc: [*]const Op) [*]const Op {
    const addr: isize = @intCast(@intFromPtr(pc));
    const offset = @as(isize, @intCast(decode(pc))) * @sizeOf(Op);
    return @ptrFromInt(@as(usize, @intCast(addr + offset)));
}

// https://swtch.com/~rsc/regexp/regexp2.html#backtrack
fn recursive(pc: [*]const Op, text: []const u8, sp: usize) bool {
    std.debug.print("sp={} {s} {c}\n", .{ sp, @tagName(pc[0]), if (pc[0] == .char) @as(u8, @intCast(decode(pc + 1))) else ' ' });

    return switch (pc[0]) {
        .begin => if (sp == 0) recursive(pc + 1, text, sp) else false,
        .end => if (sp + 1 == text.len) recursive(pc + 1, text, sp) else false,
        .char => if (sp < text.len and text[sp] == decode(pc + 1)) recursive(pc + 2, text, sp + 1) else false,
        .any => if (sp < text.len) recursive(pc + 1, text, sp + 1) else false,
        .split => recursive(decodeJmp(pc + 1), text, sp) or recursive(decodeJmp(pc + 2), text, sp),
        .jmp => recursive(decodeJmp(pc + 1), text, sp),
        .match => true,
        else => unreachable,
    };
}

// TODO: https://swtch.com/~rsc/regexp/regexp2.html#pike
fn pikevm(code: []const Op, text: []const u8, threads: []Thread) bool {
    var clist = Buf(Thread).init(threads[0 .. threads.len / 2]);
    var nlist = Buf(Thread).init(threads[threads.len / 2 ..]);

    // Initial thread
    clist.push(.{ .pc = code.ptr });

    var sp: usize = 0;
    while (true) : (sp += 1) {
        std.debug.print("sp={}\n", .{sp});

        var j: usize = 0; // ^/jmp/split needs to be processed before advancing
        while (j < clist.len) : (j += 1) { // and we do that by pushing to clist
            const pc = clist.buf[j].pc;

            switch (pc[0]) {
                .begin => if (sp == 0) clist.push(.{ .pc = pc + 1 }),
                .end => return false, // TODO (the other version does not work yet either)
                .char => if (sp < text.len and text[sp] == decode(pc + 1)) nlist.push(.{ .pc = pc + 2 }),
                .any => if (sp < text.len) nlist.push(.{ .pc = pc + 1 }),
                .jmp => clist.push(.{ .pc = decodeJmp(pc + 1) }),
                .split => {
                    clist.push(.{ .pc = decodeJmp(pc + 1) });
                    clist.push(.{ .pc = decodeJmp(pc + 2) });
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

fn expectCompile(regex: []const u8, expected: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    var w = buf.writer();
    defer buf.deinit();

    var r = try Regex.compile(std.testing.allocator, regex);
    defer r.deinit(std.testing.allocator);

    var pc: [*]const Op = r.code.ptr;
    const end = pc + r.code.len;

    while (pc != end) {
        const i = pc - r.code.ptr;

        if (i > 0) {
            try w.writeByte('\n');
        }

        try w.print("{d:>3}: {s}", .{ i, @tagName(pc[0]) });

        switch (pc[0]) {
            .char => try w.print(" {c}", .{
                @as(u8, @intCast(decode(pc + 1))),
            }),
            .jmp => try w.print(" :{d}", .{
                @as(i32, @intCast(i)) + decode(pc + 1) + 1, // relative to itself
            }),
            .split => try w.print(" :{d} :{d}", .{
                @as(i32, @intCast(i)) + decode(pc + 1) + 1, // relative to itself
                @as(i32, @intCast(i)) + decode(pc + 2) + 2, // relative to itself
            }),
            else => {},
        }

        pc += switch (pc[0]) {
            .split => 3,
            .char, .jmp => 2,
            else => 1,
        };
    }

    try std.testing.expectEqualStrings(expected, buf.items);
}

test "Regex.compile()" {
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
}

fn expectMatch(regex: []const u8, text: []const u8, expected: bool) !void {
    std.debug.print("--- {s} --- {s}\n", .{ regex, text });

    var r = try Regex.compile(std.testing.allocator, regex);
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected, r.match(text));
}

test "Regex.match()" {
    // Literal
    try expectMatch("hello", "hello", true);
    try expectMatch("hello", "hello world", true);
    try expectMatch("hello", "hi", false);

    // Dot
    try expectMatch("h.llo", "hello", true);
    try expectMatch("h.llo", "hallo", true);
    try expectMatch("h.llo", "hllo", false);

    // Question
    try expectMatch("ab?c", "ac", true);
    try expectMatch("ab?c", "abc", true);
    try expectMatch("ab?c", "abbc", false);
    try expectMatch("ab?c", "adc", false);

    // Plus
    try expectMatch("ab+c", "abc", true);
    try expectMatch("ab+c", "abbc", true);
    try expectMatch("ab+c", "ac", false);

    // Star
    try expectMatch("ab*c", "ac", true);
    try expectMatch("ab*c", "abc", true);
    try expectMatch("ab*c", "abbc", true);
    try expectMatch("ab*c", "adc", false);

    // Pipe
    try expectMatch("a|b|c", "a", true);
    try expectMatch("a|b|c", "b", true);
    try expectMatch("a|b|c", "c", true);
    try expectMatch("a|b|c", "d", false);
    try expectMatch("ab|c", "ab", true);
    try expectMatch("ab|c", "c", true);
    try expectMatch("ab|c", "d", false);

    // Group
    try expectMatch("(abc)?def", "abcdef", true);
    try expectMatch("(abc)?def", "def", true);
    try expectMatch("(abc)?def", "adef", false);
    try expectMatch("(ab)+de", "abde", true);
    try expectMatch("(ab)+de", "ababde", true);
    try expectMatch("(ab)+de", "abd", false);
    try expectMatch("(ab)*de", "abde", true);
    try expectMatch("(ab)*de", "ababde", true);
    try expectMatch("(ab)*de", "de", true);
    try expectMatch("(ab)*de", "abd", false);
    try expectMatch("(a|b)*", "aba", true);
    try expectMatch("(a|b)*c", "abbaabc", true);
    try expectMatch("(a|b)*c", "d", false);

    // Start/End
    try expectMatch("^hello", "hello world", true);
    try expectMatch("^hello", "say hello", false);
    // try expectMatch("world$", "hello world", true);
    // try expectMatch("world$", "world peace", false);

    // Empty
    try expectMatch("hello", "", false);
    try expectMatch(".*", "", true);
    try expectMatch("", "", true);
    try expectMatch("", "any", true);

    // Combination
    // try expectMatch("^a.*b$", "ab", true);
    // try expectMatch("^a.*b$", "axxxb", true);
    // try expectMatch("^a.*b$", "axxx", false);
}
