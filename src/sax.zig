const std = @import("std");

/// A SAX event.
pub const Event = union(enum) {
    open: []const u8,
    attr: struct { name: []const u8, value: []const u8 },
    close: []const u8,
    text: []const u8,

    pub const Attr = @FieldType(Event, "attr");

    pub fn format(self: Event, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try switch (self) {
            .open => writer.print("<{s}", .{self.open}),
            .attr => writer.print(" {s}=\"{s}\"", .{ self.attr.name, self.attr.value }),
            .close => writer.print("</{s}>\n", .{self.close}),
            .text => writer.print("{s}", .{self.text}),
        };
    }
};

/// A simple SAX-style XML parser that can be used for both complete input and
/// streaming. In the case of streaming, the returned strings are only valid
/// until the next event.
///
/// The parser is forgiving and will attempt to parse as much as possible. It
/// will ignore the XML header and the DOCTYPE, and it will not fail on invalid
/// characters.
///
/// Notably, it does not perform entity decoding or unquoting of attributes.
/// This is because many events are typically ignored, making such operations
/// wasteful.
pub const Parser = struct {
    buf: []u8,
    reader: std.io.AnyReader,
    is_eof: bool = false,
    scanner: Scanner = .{ .input = &.{} },

    /// Create a parser for streaming input.
    pub fn initStreaming(buf: []u8, reader: std.io.AnyReader) Parser {
        return .{
            .buf = buf,
            .reader = reader,
        };
    }

    /// Create a parser for a complete input.
    pub fn initCompleteInput(input: []const u8) Parser {
        return .{
            .is_eof = true,
            .buf = undefined,
            .reader = undefined,
            .scanner = .{
                .input = input,
            },
        };
    }

    /// Returns next event or null if we reached the end of the input.
    pub fn next(self: *Parser) !?Event {
        return self.scanner.next() orelse {
            while (!self.is_eof) {
                if (self.scanner.pos == self.scanner.input.len) {
                    try self.shrinkRead();
                }

                return self.scanner.next() orelse continue;
            }

            return self.scanner.end();
        };
    }

    fn shrinkRead(self: *Parser) !void {
        const keep = self.scanner.input[self.scanner.spos..];
        if (keep.len == self.buf.len) return error.BufferFull;

        self.scanner.pos -= self.scanner.spos;
        self.scanner.spos = 0;
        std.mem.copyForwards(u8, self.buf[0..keep.len], keep);

        const n = try self.reader.read(self.buf[keep.len..]);
        if (n == 0) self.is_eof = true;
        self.scanner.input = self.buf[0 .. keep.len + n];
    }
};

// Low-level parser, not supposed to be used directly.
// It is implemented as a state machine, one byte at a time, and without any
// pointers in the state. This makes it trivial to implement streaming in a
// memory-safe way.
const Scanner = struct {
    input: []const u8,
    pos: usize = 0, // where we are in the input
    spos: usize = 0, // where was the current state started
    keep_whitespace: bool = false, // whether to keep whitespace
    state: union(enum) {
        init,
        maybe_header,
        maybe_doctype: usize,
        skip_header,
        any, // wait for `<` or non-whitespace text
        text, // wait for `<`
        @"<", // wait for alpha, `/`, `!`, or change to .text
        @"</", // wait for alpha or change to .text
        @"</a", // wait for `>` or change to .text
        @"<!", // wait for `-`, `[` or change to .text
        @"<!-", // wait for `-` or change to .text
        @"<!--": usize, // wait for `-->`
        @"<![": usize, // wait for `CDATA[` or change to .text
        @"<![CDATA[": usize, // wait for `]]>`

        @"<a", // wait for space, `/`, or `>`
        @"<a ", // wait for alpha, `/`, or `>`
        @"<a a", // wait for `=`, space, `/`, or `/`
        @"<a a=", // wait for quote
        @"<a /", // wait for `>`
        @"a=x": struct { len: usize, q: u8 }, // wait for closing quote
    } = .init,

    const State = std.meta.FieldType(@This(), .state);

    fn next(self: *Scanner) ?Event {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            defer self.pos += 1;

            switch (self.state) {
                .any => switch (ws(ch)) {
                    ' ' => if (self.keep_whitespace) self.start(.text) else continue,
                    '<' => self.start(.@"<"),
                    else => self.start(.text),
                },

                .text => if (ch == '<') {
                    defer self.start(.@"<");
                    return .{ .text = self.input[self.spos..self.pos] };
                },

                .@"<" => self.state = switch (ch) {
                    'a'...'z', 'A'...'Z' => .@"<a",
                    '/' => .@"</",
                    '!' => .@"<!",
                    else => .text,
                },

                .@"</" => self.state = switch (ch) {
                    'a'...'z', 'A'...'Z' => .@"</a",
                    else => .text,
                },

                .@"</a" => switch (ws(ch)) {
                    '>' => {
                        defer self.startNext(.any);
                        return .{ .close = self.input[self.spos + 2 .. self.pos] };
                    },
                    ' ' => self.state = .text,
                    else => continue,
                },

                .@"<!" => self.state = switch (ch) {
                    '-' => .@"<!-",
                    '[' => .{ .@"<![" = 0 },
                    else => .text,
                },

                .@"<!-" => self.state = switch (ch) {
                    '-' => .{ .@"<!--" = 0 },
                    else => .text,
                },

                .@"<!--" => |*i| if (seq("-->", i, ch) == .match) {
                    self.startNext(.any);
                },

                .@"<![" => |*i| switch (seq("CDATA[", i, ch)) {
                    .match => self.startNext(.{ .@"<![CDATA[" = 0 }),
                    .maybe => continue,
                    else => self.state = .text,
                },

                .@"<![CDATA[" => |*i| if (seq("]]>", i, ch) == .match) {
                    defer self.startNext(.any);
                    return .{ .text = self.input[self.spos .. self.pos - 2] };
                },

                .@"<a" => {
                    const state: State = switch (ws(ch)) {
                        ' ' => .@"<a ",
                        '/' => .@"<a /",
                        '>' => .any,
                        else => continue,
                    };

                    defer self.startNext(state);
                    return .{ .open = self.input[self.spos + 1 .. self.pos] };
                },

                .@"<a " => switch (ws(ch)) {
                    'a'...'z', 'A'...'Z' => self.start(.@"<a a"),
                    '/' => self.startNext(.@"<a /"),
                    '>' => self.startNext(.any),
                    else => continue,
                },

                .@"<a a" => {
                    const state: State = switch (ws(ch)) {
                        '=' => {
                            self.state = .@"<a a=";
                            continue;
                        },
                        ' ' => .@"<a ",
                        '/' => .@"<a /",
                        '>' => .any,
                        else => continue,
                    };

                    defer self.startNext(state);
                    return .{ .attr = .{ .name = self.input[self.spos..self.pos], .value = "" } };
                },

                .@"<a a=" => switch (ch) {
                    '"', '\'' => self.state = .{ .@"a=x" = .{ .len = self.pos - self.spos - 1, .q = ch } },
                    else => continue,
                },

                .@"a=x" => |att| if (ch == att.q and self.input[self.pos - 1] != '\\') {
                    const name = self.input[self.spos .. self.spos + att.len];
                    const value = self.input[self.spos + att.len + 2 .. self.pos];

                    defer self.startNext(.@"<a ");
                    return .{ .attr = .{ .name = name, .value = value } };
                },

                .@"<a /" => switch (ch) {
                    '>' => {
                        defer self.startNext(.any);
                        return .{ .close = "" };
                    },
                    else => continue,
                },

                .init => switch (ws(ch)) {
                    ' ' => continue,
                    '<' => self.start(.maybe_header),
                    else => self.start(.text),
                },

                .maybe_header => self.state = switch (ch) {
                    '?' => .skip_header,
                    '!' => .{ .maybe_doctype = 0 },
                    'a'...'z', 'A'...'Z' => .@"<a",
                    else => .text,
                },

                .maybe_doctype => |*i| self.state = switch (seq("DOCTYPE", i, ch)) {
                    .match => .skip_header,
                    .maybe => continue,
                    else => .text,
                },

                .skip_header => if (ch == '>') {
                    self.state = .init;
                },
            }
        }

        return null;
    }

    fn end(self: *Scanner) ?Event {
        switch (self.state) {
            .text => {
                defer self.start(.any);
                return .{ .text = self.input[self.spos..] };
            },
            else => return null,
        }
    }

    fn start(self: *Scanner, state: State) void {
        self.spos = self.pos;
        self.state = state;
    }

    fn startNext(self: *Scanner, state: State) void {
        self.spos = self.pos + 1;
        self.state = state;
    }

    fn ws(ch: u8) u8 {
        return switch (ch) {
            ' ', '\t', '\r', '\n' => ' ',
            else => ch,
        };
    }

    fn seq(str: []const u8, i: *usize, ch: u8) enum { no_match, maybe, match } {
        i.* = if (str[i.*] == ch) i.* + 1 else 0;
        return if (i.* == str.len) .match else if (i.* > 0) .maybe else .no_match;
    }
};

fn expectEvents(input: []const u8, events: []const Event) !void {
    var buf: [40]u8 = undefined;
    var fbs = std.io.fixedBufferStream(input);

    var parsers: [2]Parser = .{
        .initCompleteInput(input),
        .initStreaming(&buf, fbs.reader().any()),
    };

    for (&parsers) |*parser| {
        for (events, 0..) |tag, i| {
            const ev = try parser.next() orelse return error.Eof;
            errdefer std.debug.print("#{} event({s}): {any}\n", .{ i, @tagName(ev), ev });

            try std.testing.expectEqualDeep(tag, ev);
        }

        try std.testing.expectEqual(null, parser.next());
        // try std.testing.expectEqual(input.len, parser.pos);
    }
}

// TODO: strip \0?

test "empty" {
    try expectEvents("", &.{});
    try expectEvents(" ", &.{});
    try expectEvents(" \n \t \n ", &.{});
}

test "self-closing" {
    try expectEvents("<root/>", &.{
        .{ .open = "root" },
        .{ .close = "" },
    });

    try expectEvents("<root />", &.{
        .{ .open = "root" },
        .{ .close = "" },
    });
}

test "text" {
    try expectEvents("<root>text</root>", &.{
        .{ .open = "root" },
        .{ .text = "text" },
        .{ .close = "root" },
    });
}

test "comments" {
    try expectEvents("<root><!-- empty --></root>", &.{
        .{ .open = "root" },
        .{ .close = "root" },
    });

    try expectEvents("<root>foo<!-- empty -->bar</root>", &.{
        .{ .open = "root" },
        .{ .text = "foo" },
        .{ .text = "bar" },
        .{ .close = "root" },
    });
}

test "cdata" {
    try expectEvents("<root><![CDATA[text]]></root>", &.{
        .{ .open = "root" },
        .{ .text = "text" },
        .{ .close = "root" },
    });
}

test "attributes" {
    try expectEvents("<root foo=\"bar\" />", &.{
        .{ .open = "root" },
        .{ .attr = .{ .name = "foo", .value = "bar" } },
        .{ .close = "" },
    });

    try expectEvents("<root foo='bar' />", &.{
        .{ .open = "root" },
        .{ .attr = .{ .name = "foo", .value = "bar" } },
        .{ .close = "" },
    });

    try expectEvents("<root foo=\"'bar'\" />", &.{
        .{ .open = "root" },
        .{ .attr = .{ .name = "foo", .value = "'bar'" } },
        .{ .close = "" },
    });

    try expectEvents("<root foo='bar\\'' />", &.{
        .{ .open = "root" },
        .{ .attr = .{ .name = "foo", .value = "bar\\'" } }, // TODO: unescape
        .{ .close = "" },
    });

    try expectEvents("<root att />", &.{
        .{ .open = "root" },
        .{ .attr = .{ .name = "att", .value = "" } },
        .{ .close = "" },
    });

    try expectEvents("<root att/>", &.{
        .{ .open = "root" },
        .{ .attr = .{ .name = "att", .value = "" } },
        .{ .close = "" },
    });

    try expectEvents("<root att></root>", &.{
        .{ .open = "root" },
        .{ .attr = .{ .name = "att", .value = "" } },
        .{ .close = "root" },
    });
}

test "children" {
    try expectEvents("<root><child>text</child></root>", &.{
        .{ .open = "root" },
        .{ .open = "child" },
        .{ .text = "text" },
        .{ .close = "child" },
        .{ .close = "root" },
    });
}

test "skip doctype" {
    try expectEvents("<!DOCTYPE html><root>text</root>", &.{
        .{ .open = "root" },
        .{ .text = "text" },
        .{ .close = "root" },
    });
}

test "skip xml header" {
    try expectEvents(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root>text</root>
    ,
        &.{
            .{ .open = "root" },
            .{ .text = "text" },
            .{ .close = "root" },
        },
    );
}

test "forgiving" {
    try expectEvents("<root>foo<!foo>bar</root>", &.{
        .{ .open = "root" },
        .{ .text = "foo" },
        .{ .text = "<!foo>bar" },
        .{ .close = "root" },
    });
}
