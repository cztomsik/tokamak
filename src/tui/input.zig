const std = @import("std");

pub const Key = union(enum) {
    // zig fmt: off
    char: u21,
    up, down, left, right,
    home, end, page_up, page_down,
    tab, shift_tab, enter, backspace, delete, escape,
    ctrl_c, ctrl_d,
    paste_start, paste_end,
    scroll_up, scroll_down,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    unknown,
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
        0x1B => if (try pollReadable(stdin, 1000)) try readCSI(stdin) else .escape,
        '\t' => .tab,
        '\r', '\n' => .enter,
        0x7F, 0x08 => .backspace,
        else => .{ .char = try readUtf8(stdin, ch) },
    };
}

fn readCSI(stdin: *std.fs.File.Reader) Error!Key {
    switch (try readMore(stdin)) {
        // macOS terminal app
        'O' => switch (try readMore(stdin)) {
            'P' => return .f1,
            'Q' => return .f2,
            'R' => return .f3,
            'S' => return .f4,
            else => return .unknown,
        },
        '[' => {}, // read & decode
        else => return .unknown,
    }

    var seq: [32]u8 = undefined;
    var i: u5 = 0;

    while (i < seq.len) {
        const ch = try readMore(stdin);
        seq[i] = ch;
        i += 1;
        if (ch >= 0x40 and ch <= 0x7E) break; // this was final byte
    }

    return decodeCSI(seq[0..i]);
}

fn readUtf8(stdin: *std.fs.File.Reader, first: u8) Error!u21 {
    const seq_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (seq_len == 1) return first;
    var buf: [4]u8 = .{ first, undefined, undefined, undefined };
    for (1..seq_len) |i| buf[i] = try readMore(stdin);
    return std.unicode.utf8Decode(buf[0..seq_len]) catch first;
}

fn readMore(stdin: *std.fs.File.Reader) Error!u8 {
    while (!try pollReadable(stdin, 1_000)) {}
    return (try stdin.interface.take(1))[0];
}

fn decodeCSI(seq: []const u8) Key {
    const params = seq[0 .. seq.len - 1];
    const final = seq[seq.len - 1];

    if (final >= 'A' and final <= 'F') {
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => unreachable,
        };
    }

    if (final == 'Z' and params.len == 0) {
        return .shift_tab;
    }

    if (final == 'M' or final == 'm') {
        // TODO: decodeMouse()
        if (std.mem.startsWith(u8, params, "<64")) return .scroll_up;
        if (std.mem.startsWith(u8, params, "<65")) return .scroll_down;
        return .unknown;
    }

    if (final != '~') return .unknown;

    return switch (std.fmt.parseInt(u8, params, 10) catch 0) {
        1, 7 => .home,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11 => .f1,
        12 => .f2,
        13 => .f3,
        14 => .f4,
        15 => .f5,
        17 => .f6,
        18 => .f7,
        19 => .f8,
        20 => .f9,
        21 => .f10,
        23 => .f11,
        24 => .f12,
        200 => .paste_start,
        201 => .paste_end,
        else => .unknown,
    };
}

test decodeCSI {
    try std.testing.expectEqual(.up, decodeCSI("A"));
    try std.testing.expectEqual(.delete, decodeCSI("3~"));
    try std.testing.expectEqual(.paste_start, decodeCSI("200~"));
    try std.testing.expectEqual(.f12, decodeCSI("24~"));

    try std.testing.expectEqual(.scroll_up, decodeCSI("<64;15;15M"));
    try std.testing.expectEqual(.scroll_down, decodeCSI("<65;15;15M"));
}
