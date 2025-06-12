const std = @import("std");
const Buf = @import("util.zig").Buf;

// https://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html
// https://swtch.com/~rsc/regexp/regexp1.html
// https://swtch.com/~rsc/regexp/regexp2.html
// https://swtch.com/~rsc/regexp/regexp3.html
pub const Regex = struct {
    code: []const Op,

    pub fn compile(allocator: std.mem.Allocator, regex: []const u8) !Regex {
        const len, const depth = try countAndValidate(regex);

        var code: Buf(Op) = try .initAlloc(allocator, len);
        errdefer code.deinit(allocator);

        var stack: Buf(i32) = try .initAlloc(allocator, depth);
        defer stack.deinit(allocator);

        var prev_atom: i32 = -1;
        var hole_other_branch: i32 = -1;

        for (regex) |ch| {
            const end: i32 = @intCast(code.len);

            switch (ch) {
                '^' => code.push(.begin),
                '$' => code.push(.begin),
                '(' => stack.push(end),
                ')' => prev_atom = stack.pop().?,

                '?' => {
                    code.insertSlice(@intCast(prev_atom), &.{
                        .split,
                        encodeJmp(2), // run the check
                        encodeJmp(end - prev_atom + 1), // jump out otherwise
                    });
                },

                '+' => {
                    code.push(.split);
                    code.push(encodeJmp(prev_atom - end - 1)); // repeat
                    code.push(encodeJmp(1)); // jump out otherwise
                },

                '*' => {
                    code.insertSlice(@intCast(prev_atom), &.{
                        .split,
                        encodeJmp(2), // run the check
                        encodeJmp(end - prev_atom + 3), // jump out otherwise
                    });

                    code.push(.jmp);
                    code.push(encodeJmp(prev_atom - end - 4)); // keep repeating
                },

                '|' => {
                    // TODO: groups? can we just put it in the stack?
                    code.insertSlice(@intCast(hole_other_branch + 1), &.{
                        .split,
                        encodeJmp(2), // LHS branch (which ends with holey-jmp)
                        encodeJmp(end - hole_other_branch + 2), // RHS
                    });

                    // Point any previous hole to our newly created holey-jmp (double-jump)
                    // NOTE: we could probably inline/flatten these in a second-pass (optimization?)
                    if (hole_other_branch > 0) {
                        code.buf[@intCast(hole_other_branch)] = encodeJmp(@as(i32, @intCast(code.len)) - hole_other_branch); // relative to the jmp itself
                    }

                    // Create a jump with a hole
                    code.push(.jmp);
                    hole_other_branch = @intCast(code.len);
                    code.push(undefined);
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
            code.buf[@intCast(hole_other_branch)] = encodeJmp(end - hole_other_branch); // relative to the jmp itself
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
        // TODO: implement & switch to pikevm(), or maybe only do that for longer texts?
        return recursive(self.code.ptr, text, 0);
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

fn encodeJmp(offset: i32) Op {
    return encode(offset * @sizeOf(Op));
}

fn decode(pc: [*]const Op) i32 {
    return @intFromEnum(pc[0]);
}

fn decodeJmp(pc: [*]const Op) [*]const Op {
    const addr: isize = @intCast(@intFromPtr(pc));
    return @ptrFromInt(@as(usize, @intCast(addr + decode(pc))));
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
// fn pikevm(pc: [*]const Op, text: []const u8, sp: usize) bool {
//     while (pos < text.len) {}
// }

const expect = std.testing.expect;

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
