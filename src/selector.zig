const std = @import("std");

const Token = union(enum) {
    tag: []const u8,
    id: []const u8,
    class: []const u8,
    star,
    gt,
    plus,
    tilde,
    comma,
};

// subset of https://github.com/cztomsik/graffiti/blob/master/src/css/tokenizer.zig
const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,
    space_before: bool = false,

    pub fn next(self: *Tokenizer) !?Token {
        const ch = self.peek() orelse return null;
        self.pos += 1;

        // TODO: is this enough?
        if (ch != ' ') self.space_before = false;

        return switch (ch) {
            'a'...'z', 'A'...'Z', '-', '_' => .{ .tag = try self.expectIdent(self.pos - 1) },
            '#' => .{ .id = try self.expectIdent(self.pos) },
            '.' => .{ .class = try self.expectIdent(self.pos) },
            '*' => .star,
            '>' => .gt,
            '+' => .plus,
            '~' => .tilde,
            ',' => .comma,
            ' ' => {
                const tok = try self.next();
                self.space_before = true;
                return tok;
            },
            else => error.InvalidSelector,
        };
    }

    fn peek(self: *Tokenizer) ?u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    fn expectIdent(self: *Tokenizer, start: usize) ![]const u8 {
        while (self.pos < self.input.len) switch (self.input[self.pos]) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => self.pos += 1,
            else => break,
        };
        return if (self.pos > start) self.input[start..self.pos] else error.ExpectedIdent;
    }
};

// https://github.com/cztomsik/graffiti/blob/master/src/css/selector.zig
// But this time we are not trying to reimplement the whole browser
pub const Selector = struct {
    parts: []const Part,

    const Part = union(enum) {
        // components
        unsupported,
        universal,
        local_name: []const u8,
        identifier: []const u8,
        class_name: []const u8,

        // combinators
        parent,
        ancestor,
        previous_sibling,
        @"or",
    };

    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        allocator.free(self.parts);
    }

    pub fn parse(allocator: std.mem.Allocator, selector: []const u8) !Selector {
        var parts = std.ArrayList(Part).init(allocator);
        defer parts.deinit();

        var tokenizer = Tokenizer{ .input = selector };
        var pending_combinator: ?Part = null;

        while (try tokenizer.next()) |tok| {
            const component: ?Part = switch (tok) {
                .star => Part.universal,
                .tag => |tag| Part{ .local_name = tag },
                .id => |id| Part{ .identifier = id },
                .class => |class| Part{ .class_name = class },
                else => null,
            };

            if (component) |comp| {
                if (pending_combinator) |comb| {
                    try parts.append(comb);
                } else if (tokenizer.space_before) {
                    try parts.append(Part.ancestor);
                }

                try parts.append(comp);
                pending_combinator = null;
            } else {
                if (pending_combinator != null) return error.ExpectedComponent;

                pending_combinator = switch (tok) {
                    .gt => Part.parent,
                    .plus => Part.previous_sibling,
                    .tilde => Part.unsupported,
                    .comma => Part.@"or",
                    else => return error.ExpectedCombinator,
                };
            }
        }

        if (parts.items.len == 0 or pending_combinator != null) {
            return error.Eof;
        }

        // save in reverse
        std.mem.reverse(Part, parts.items);

        return .{
            .parts = try parts.toOwnedSlice(),
        };
    }

    pub fn format(self: Selector, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        for (0..self.parts.len) |i| {
            try switch (self.parts[self.parts.len - 1 - i]) {
                .unsupported => writer.print(":unsupported", .{}),
                .universal => writer.print("*", .{}),
                .local_name => |s| writer.print("{s}", .{s}),
                .identifier => |s| writer.print("#{s}", .{s}),
                .class_name => |s| writer.print(".{s}", .{s}),
                .parent => writer.print(" > ", .{}),
                .previous_sibling => writer.print(" + ", .{}),
                .ancestor => writer.print(" ", .{}),
                .@"or" => writer.print(", ", .{}),
            };
        }
    }

    pub fn match(self: *Selector, element: anytype) bool {
        // state
        var i: usize = 0;
        var current = element;
        var parent = false;
        var ancestors = false;

        next_part: while (i < self.parts.len) : (i += 1) {
            switch (self.parts[i]) {
                .parent => parent = true,
                .ancestor => ancestors = true,
                .previous_sibling => current = current.previousElementSibling() orelse break,
                // end-of-branch and we still have a match, no need to check others
                .@"or" => break :next_part,
                else => |comp| {
                    while (true) {
                        if (parent or ancestors) {
                            parent = false;
                            current = current.parentElement() orelse break;
                        }

                        if (matchComponent(comp, current)) {
                            ancestors = false;
                            continue :next_part;
                        }

                        // we got no match on parent
                        if (!ancestors) {
                            break;
                        }
                    }

                    // no match, fast-forward to next OR
                    while (i < self.parts.len) : (i += 1) {
                        if (self.parts[i] == .@"or") {
                            // reset stack
                            current = element;
                            continue :next_part;
                        }
                    }

                    // or fail otherwise
                    return false;
                },
            }
        }

        // everything was fine
        return true;
    }

    fn matchComponent(comp: Part, element: anytype) bool {
        return switch (comp) {
            .universal => true,
            .local_name => |name| std.mem.eql(u8, element.localName(), name),
            .identifier => |id| std.mem.eql(u8, element.id(), id),
            .class_name => |cls| {
                var parts = std.mem.tokenizeScalar(u8, element.className(), ' ');
                while (parts.next()) |s| if (std.mem.eql(u8, s, cls)) return true;
                return false;
            },
            else => unreachable,
        };
    }
};

pub fn QuerySelectorIterator(comptime E: type) type {
    return struct {
        allocator: std.mem.Allocator,
        selector: Selector,
        next_element: ?E,

        pub fn init(allocator: std.mem.Allocator, selector: []const u8, start: ?E) !@This() {
            return .{
                .allocator = allocator,
                .selector = try Selector.parse(allocator, selector),
                .next_element = start,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.selector.deinit(self.allocator);
        }

        pub fn next(self: *@This()) ?E {
            while (self.next_element) |el| {
                self.next_element = el.firstElementChild() orelse el.nextElementSibling() orelse nextInOrder(el);
                if (self.selector.match(el)) return el;
            } else return null;
        }

        fn nextInOrder(el: E) ?E {
            var next_parent = el.parentElement();
            while (next_parent) |parent| : (next_parent = parent.parentElement()) {
                return parent.nextElementSibling() orelse continue;
            } else return null;
        }
    };
}

const Fixture = struct {
    parents: []const ?usize,
    prevs: []const ?usize,
    local_names: []const []const u8,
    ids: []const []const u8,
    class_names: []const []const u8,

    const El = struct {
        cx: *const Fixture,
        i: usize,

        fn parentElement(self: El) ?El {
            return if (self.cx.parents[self.i]) |i| .{ .cx = self.cx, .i = i } else null;
        }

        fn previousElementSibling(self: El) ?El {
            return if (self.cx.prevs[self.i]) |i| .{ .cx = self.cx, .i = i } else null;
        }

        fn localName(self: El) []const u8 {
            return self.cx.local_names[self.i];
        }

        fn id(self: El) []const u8 {
            return self.cx.ids[self.i];
        }

        fn className(self: El) []const u8 {
            return self.cx.class_names[self.i];
        }
    };

    fn expectMatch(self: *const Fixture, selector: []const u8, index: usize) !void {
        var sel = try Selector.parse(std.testing.allocator, selector);
        defer sel.deinit(std.testing.allocator);

        try std.testing.expect(sel.match(El{ .cx = self, .i = index }));
    }
};

test "parsing & fmt" {
    const examples = .{
        // single-component
        "body",
        "h2",
        "#app",
        ".btn",

        // multi-component
        ".btn.btn-primary",
        "*.test",
        "div#app.test",

        // with combinators
        "div .btn",
        "span + img",
        "body > div.test div#test",

        // multi-branch
        "html, body",
        "body > div, div button span",

        // TODO
        // ":root",
        // "a ~ b",
    };

    inline for (examples) |ex| {
        var sel = try Selector.parse(std.testing.allocator, ex);
        defer sel.deinit(std.testing.allocator);

        try std.testing.expectFmt(ex, "{}", .{sel});
    }

    const invalid = .{
        .{ "", error.Eof },
        .{ " ", error.Eof },
        .{ "a,", error.Eof },
        .{ "a,,b", error.ExpectedComponent },
        .{ "a>>b", error.ExpectedComponent },
    };

    inline for (invalid) |ex| {
        try std.testing.expectError(ex[1], Selector.parse(std.testing.allocator, ex[0]));
    }
}

test "matching" {
    const cx = Fixture{
        .parents = &.{ null, 0, 1, 2, 3, 3 },
        .prevs = &.{ null, null, null, null, null, 4 },
        .local_names = &.{ "html", "body", "div", "button", "span", "img" },
        .ids = &.{ "", "app", "panel", "", "", "" },
        .class_names = &.{ "", "", "", "btn", "", "" },
    };

    // single-component
    try cx.expectMatch("*", 0);
    try cx.expectMatch("html", 0);
    try cx.expectMatch("body", 1);
    try cx.expectMatch("#app", 1);
    try cx.expectMatch("div", 2);
    try cx.expectMatch("#panel", 2);
    try cx.expectMatch("button", 3);
    try cx.expectMatch(".btn", 3);
    try cx.expectMatch("span", 4);

    // multi-component
    try cx.expectMatch("body#app", 1);
    try cx.expectMatch("div#panel", 2);
    try cx.expectMatch("button.btn", 3);

    // sibling
    try cx.expectMatch("span + img", 5);
    try cx.expectMatch(".btn > span + img", 5);

    // parent
    try cx.expectMatch("button > span", 4);
    try cx.expectMatch("div#panel > button.btn > span", 4);

    // ancestor
    try cx.expectMatch("button span", 4);
    try cx.expectMatch("div#panel span", 4);
    try cx.expectMatch("html body div button span", 4);
    try cx.expectMatch("body div .btn span", 4);

    // OR
    try cx.expectMatch("div, span", 4);
    try cx.expectMatch("a, b, c, span, d", 4);
    try cx.expectMatch("html, body", 1);

    // any combination
    try cx.expectMatch("div, span.foo, #panel span", 4);
    try cx.expectMatch("a b c d e f g, span", 4);
}
