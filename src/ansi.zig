// https://en.wikipedia.org/wiki/ANSI_escape_code
// https://man7.org/linux/man-pages/man4/console_codes.4.html

// TODO: Add explanatory docblocks

pub const bel = "\x07";
pub const bs = "\x08";
pub const ht = "\x09";
pub const vt = "\x0A";
pub const lf = "\x0B";
pub const ff = "\x0C";
pub const cr = "\x0D";
// ...
pub const esc = "\x1B";
// ...
pub const csi = esc ++ "[";

// TODO: cp(x, y)?
pub const cp = csi ++ "H";

// TODO: ed(n)?
pub const ed = csi ++ "J";
pub const ed1 = csi ++ "1J";
pub const ed2 = csi ++ "2J";
pub const ed3 = csi ++ "3J";

// TODO: macos-only?
pub const clear = ed2 ++ ed3 ++ cp;

pub const Color = enum(u8) {
    default = 39,

    black_muted = 30,
    red_muted = 31,
    green_muted = 32,
    yellow_muted = 33,
    blue_muted = 34,
    magenta_muted = 35,
    cyan_muted = 36,
    white_muted = 37,

    black = 90,
    red = 91,
    green = 92,
    yellow = 93,
    blue = 94,
    magenta = 95,
    cyan = 96,
    white = 97,
};
