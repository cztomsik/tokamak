const std = @import("std");

// https://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html
pub fn match(regex: []const u8, text: []const u8) bool {
    // Simplest case
    if (regex.len > 0 and regex[0] == '^') {
        return matchHere(regex[1..], text);
    }

    // Otherwise we need to try repeatedly at every position.
    var i: usize = 0;
    while (true) : (i += 1) {
        if (matchHere(regex, text[i..])) {
            return true;
        }

        // Do-while (i < text.len)
        if (i >= text.len) break;
    }

    return false;
}

fn matchHere(regex: []const u8, text: []const u8) bool {
    if (regex.len == 0) {
        return true;
    }

    if (regex.len >= 2 and regex[1] == '*') {
        return matchStar(regex[0], regex[2..], text);
    }

    if (regex[0] == '$' and regex.len == 1) {
        return text.len == 0;
    }

    if (text.len > 0 and (regex[0] == '.' or regex[0] == text[0])) {
        return matchHere(regex[1..], text[1..]);
    }

    return false;
}

fn matchStar(c: u8, regex: []const u8, text: []const u8) bool {
    var i: usize = 0;

    while (true) : (i += 1) {
        if (matchHere(regex, text[i..])) {
            return true;
        }

        if (i >= text.len or (text[i] != c and c != '.')) {
            break;
        }
    }

    return false;
}

const expect = std.testing.expect;

test match {
    // Literal
    try expect(match("hello", "hello"));
    try expect(match("hello", "hello world"));
    try expect(!match("hello", "hi"));

    // Dot
    try expect(match("h.llo", "hello"));
    try expect(match("h.llo", "hallo"));
    try expect(!match("h.llo", "hllo"));

    // Star
    try expect(match("ab*c", "ac"));
    try expect(match("ab*c", "abc"));
    try expect(match("ab*c", "abbbbc"));
    try expect(!match("ab*c", "adc"));

    // Start/End
    try expect(match("^hello", "hello world"));
    try expect(!match("^hello", "say hello"));
    try expect(match("world$", "hello world"));
    try expect(!match("world$", "world peace"));

    // Empty
    try expect(!match("hello", ""));
    try expect(match(".*", ""));
    try expect(match("", ""));
    try expect(match("", "any"));

    // Combination
    try expect(match("^a.*b$", "ab"));
    try expect(match("^a.*b$", "axxxb"));
    try expect(!match("^a.*b$", "axxx"));
}
