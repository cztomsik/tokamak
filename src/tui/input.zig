const std = @import("std");
const ansi = @import("../ansi.zig");

pub const Key = union(enum) {
    // zig fmt: off
    char: u21,
    up, down, left, right,
    home, end, page_up, page_down,
    tab, shift_tab, enter, backspace, delete, escape,
    ctrl_c, ctrl_d,
    paste_start, paste_end,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    // zig fmt: on
};

const Error = error{ PollFailed, EndOfStream, ReadFailed };

/// Poll for a key without blocking. Returns null if no key is available.
/// timeout is in ms.
/// NOTE: This is incomplete, but it's not worth fixing until Zig v0.18
pub fn pollKey(stdin: *std.fs.File.Reader, timeout_ms: i32) Error!?Key {
    return if (try pollReadable(stdin, timeout_ms)) try readKey(stdin) else null;
}

pub fn pollReadable(stdin: *std.fs.File.Reader, timeout_ms: i32) Error!bool {
    if (stdin.interface.bufferedLen() > 0) {
        return true;
    }

    var pfd: [1]std.posix.pollfd = .{.{
        .fd = stdin.file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const rc = std.posix.poll(&pfd, timeout_ms) catch return error.PollFailed;
    if (rc == 0) return false;
    try stdin.interface.fill(1);
    return true;
}

pub fn readKey(stdin: *std.fs.File.Reader) Error!Key {
    const ch = (try stdin.interface.take(1))[0];

    return switch (ch) {
        0x03 => .ctrl_c,
        0x04 => .ctrl_d,
        ansi.esc[0] => try readCSI(stdin),
        '\t' => .tab,
        '\r', '\n' => .enter,
        0x7F, 0x08 => .backspace,
        else => .{ .char = try readUtf8(stdin, ch) },
    };
}

fn readMore(stdin: *std.fs.File.Reader) Error!u8 {
    while (!try pollReadable(stdin, 1_000)) {}
    return (try stdin.interface.take(1))[0];
}

fn readUtf8(stdin: *std.fs.File.Reader, first: u8) Error!u21 {
    const seq_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (seq_len == 1) return first;
    var buf: [4]u8 = .{ first, undefined, undefined, undefined };
    for (1..seq_len) |i| buf[i] = try readMore(stdin);
    return std.unicode.utf8Decode(buf[0..seq_len]) catch first;
}

fn readCSI(stdin: *std.fs.File.Reader) Error!Key {
    const ch = try readMore(stdin);
    const reader = &stdin.interface;

    // SS3 sequences (\x1bO.): macOS terminals send F1-F4 this way
    if (ch == 'O') return switch (try readMore(stdin)) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        else => .escape,
    };

    if (ch != '[') return .escape; // Not a CSI

    return switch (try readMore(stdin)) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .shift_tab,
        '1' => {
            const fkey: Key = switch (try readMore(stdin)) {
                '~' => .home,
                '1' => .f1,
                '2' => .f2,
                '3' => .f3,
                '4' => .f4,
                '5' => .f5,
                '7' => .f6,
                '8' => .f7,
                '9' => .f8,
                else => return .escape,
            };

            reader.toss(1); // ~
            return fkey;
        },
        '2' => {
            const b = try readMore(stdin);
            switch (b) {
                '0' => {
                    const b2 = try readMore(stdin);
                    if (b2 == '~') return .f9; // \x1b[20~
                    // \x1b[200~ or \x1b[201~
                    reader.toss(1); // ~
                    return switch (b2) {
                        '0' => .paste_start,
                        '1' => .paste_end,
                        else => .escape,
                    };
                },
                '1' => {
                    reader.toss(1);
                    return .f10;
                },
                '3' => {
                    reader.toss(1);
                    return .f11;
                },
                '4' => {
                    reader.toss(1);
                    return .f12;
                },
                else => return .escape,
            }
        },
        '3' => {
            reader.toss(1); // ~
            return .delete;
        },
        '4' => {
            reader.toss(1);
            return .end;
        },
        '5' => {
            reader.toss(1);
            return .page_up;
        },
        '6' => {
            reader.toss(1);
            return .page_down;
        },
        else => .escape,
    };
}
