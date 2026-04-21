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

pub fn readKey(reader: *std.io.Reader) !Key {
    const ch = try readByte(reader);

    return switch (ch) {
        0x03 => .ctrl_c,
        0x04 => .ctrl_d,
        ansi.esc[0] => try readCSI(reader),
        '\t' => .tab,
        '\r', '\n' => .enter,
        0x7F, 0x08 => .backspace,
        else => .{ .char = try readUtf8(reader, ch) },
    };
}

fn readByte(reader: *std.io.Reader) !u8 {
    return (try reader.take(1))[0];
}

fn readUtf8(reader: *std.io.Reader, first: u8) !u21 {
    const seq_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (seq_len == 1) return first;
    var buf: [4]u8 = .{ first, undefined, undefined, undefined };
    for (1..seq_len) |i| buf[i] = try readByte(reader);
    return std.unicode.utf8Decode(buf[0..seq_len]) catch first;
}

fn readCSI(reader: *std.io.Reader) !Key {
    const ch = try readByte(reader);

    // SS3 sequences (\x1bO.): macOS terminals send F1-F4 this way
    if (ch == 'O') return switch (try readByte(reader)) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        else => .escape,
    };

    if (ch != '[') return .escape; // Not a CSI

    return switch (try readByte(reader)) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .shift_tab,
        '1' => {
            const fkey: Key = switch (try readByte(reader)) {
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
            const b = try readByte(reader);
            switch (b) {
                '0' => {
                    const b2 = try readByte(reader);
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
