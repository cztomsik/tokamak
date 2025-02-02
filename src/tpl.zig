const std = @import("std");
const meta = @import("meta.zig");
const Vec = @import("vec.zig").Vec;

pub fn raw(allocator: std.mem.Allocator, comptime template: []const u8, data: anytype) ![]const u8 {
    const tpl = comptime Template.parseComptime(template);

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try tpl.render(&buf, data);
    return buf.toOwnedSlice();
}

test raw {
    // const res = try raw(std.testing.allocator, "{{foo}}", .{ .foo = 123 });
    // defer std.testing.allocator.free(res);
    // try std.testing.expectEqualStrings("123", res);
}

const Template = struct {
    tokens: []const Token,

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Template {
        var tokenizer = Tokenizer{ .input = input };

        const len, const depth = try tokenizer.count();

        var tokens = try Vec(Token).initCapacity(allocator, len);
        errdefer tokens.deinit(allocator);

        var stack = try Vec(usize).initCapacity(allocator, depth);
        defer stack.deinit(allocator);

        while (tokenizer.next()) |tok| {
            switch (tok) {
                .section_open => {
                    stack.push(tokens.i);
                    tokens.push(tok);
                },

                .section_close => |name| {
                    const start = stack.pop() orelse return error.MissingSectionOpen;
                    const open = &tokens.buf[start].section_open;

                    if (!std.mem.eql(u8, name, open.name)) {
                        return error.MismatchedSection;
                    }

                    open.outer_len = tokens.i - start;
                },

                else => tokens.push(tok),
            }
        }

        return .{
            .tokens = tokens.finish(),
        };
    }

    pub fn parseComptime(comptime input: []const u8) Template {
        return comptime parse(undefined, input) catch |e| @compileError(@errorName(e));
    }

    pub fn deinit(self: *Template, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
    }

    pub fn render(self: *const Template, buf: *std.ArrayList(u8), data: anytype) !void {
        try renderPart(buf, self.tokens, .{ .object = Ref.fromPtr(@TypeOf(data), &data) });
    }

    fn renderPart(buf: *std.ArrayList(u8), tokens: []const Token, data: Value) !void {
        var i: usize = 0;

        while (i < tokens.len) : (i += 1) {
            switch (tokens[i]) {
                .text => |text| try buf.appendSlice(text),

                .variable => |name| {
                    try Value.render(
                        if (name.len == 1 and name[0] == '.') data else data.resolve(name),
                        buf,
                    );
                },

                .section_open => |sec| {
                    defer i += sec.outer_len + 1;
                    const part = tokens[i + 1 .. i + sec.outer_len];
                    const val = data.resolve(sec.name);

                    if (sec.inverted == val.truthy()) {
                        continue;
                    }

                    if (sec.inverted) {
                        try renderPart(buf, part, data);
                        continue;
                    }

                    switch (val) {
                        .object => try renderPart(buf, part, val),
                        // .array => |arr| for (arr.items) |it| try renderPart(buf, next, it),
                        else => try renderPart(buf, part, data),
                    }
                },

                else => unreachable,
            }
        }
    }
};

fn expectRender(tpl: Template, data: anytype, expected: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try tpl.render(&buf, data);
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "Template" {
    var tpl = try Template.parse(std.testing.allocator, "Hello {{#name}}{{name}}{{/name}}{{^name}}World{{/name}}");
    defer tpl.deinit(std.testing.allocator);

    try expectRender(tpl, .{ .name = "Alice" }, "Hello Alice");
    // try expectRender(tpl, .{ .name = null }, "Hello World");
    // try expectRender(tpl, .{ .name = "" }, "Hello World");
    // try expectRender(tpl, .{ .name = [_]u32{} }, "Hello World");
    // try expectRender(tpl, .{ .name = struct {}{} }, "Hello ");

    var tpl2 = try Template.parse(std.testing.allocator, "{{#names}}- {{.}}\n{{/names}}{{^names}}No names{{/names}}");
    defer tpl2.deinit(std.testing.allocator);

    // try expectRender(tpl2, .{ .names = .{} }, "No names");
    // try expectRender(tpl2, .{ .names = .{ "first", "second" } }, "- first\n- second\n");
}

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    object: Ref,

    fn fromPtr(ptr: anytype) Value {
        const T = @TypeOf(ptr.*);

        return switch (T) {
            @TypeOf(null) => .null,
            bool => .{ .bool = ptr.* },
            @TypeOf(1) => .{ .int = @intCast(ptr.*) },
            else => {
                if (comptime meta.isString(T)) return .{ .string = ptr.* };

                @panic("TODO");
            },
        };
    }

    fn truthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |v| v,
            inline .int, .float => |v| v != 0,
            .string => |s| s.len > 0,
            else => true,
        };
    }

    fn resolve(self: Value, name: []const u8) Value {
        return switch (self) {
            .object => |o| o.resolve(o.ptr, name),
            else => .null,
        };
    }

    fn render(self: Value, buf: *std.ArrayList(u8)) !void {
        switch (self) {
            .null => {},
            .bool => |v| try buf.appendSlice(if (v) "true" else "false"),
            inline .int, .float => |v| try buf.writer().print("{}", .{v}),
            .string => |v| try buf.appendSlice(v),
            inline else => @panic("TODO"),
        }
    }
};

const Ref = struct {
    ptr: *const anyopaque,
    resolve: Resolver,

    const Resolver = *const fn (cx: *const anyopaque, name: []const u8) Value;

    fn fromPtr(comptime T: type, ptr: *const T) Ref {
        switch (@typeInfo(T)) {
            .@"struct" => {
                const H = struct {
                    fn resolve(cx: *const anyopaque, name: []const u8) Value {
                        const self: *const T = @ptrFromInt(@intFromPtr(cx));

                        inline for (std.meta.fields(T)) |f| {
                            if (f.is_comptime) { // otherwise: runtime value contains reference to comptime var
                                const copy = @field(self, f.name);
                                return Value.fromPtr(&copy);
                            }

                            if (std.mem.eql(u8, f.name, name)) {
                                return Value.fromPtr(&@field(self, f.name));
                            }
                        }

                        return .null;
                    }
                };

                return .{ .ptr = ptr, .resolve = H.resolve };
            },
            else => @compileError("TODO"),
        }
    }
};

const Token = union(enum) {
    text: []const u8,
    variable: []const u8,
    section_open: struct {
        name: []const u8,
        inverted: bool = false,
        outer_len: usize = 0,
    },
    section_close: []const u8,
};

const Tag = std.meta.Tag(Token);

const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    fn count(self: *Tokenizer) ![2]usize {
        const pos = self.pos;
        var len: usize = 0;
        var depth: usize = 0;
        var max_depth: usize = 0;

        while (self.next()) |t| {
            if (t == .section_close) {
                depth -= 1;
                continue;
            } else if (t == .section_open) {
                depth += 1;
                max_depth = @max(max_depth, depth);
            }

            len += 1;
        }

        self.pos = pos;
        return .{ len, max_depth };
    }

    fn next(self: *Tokenizer) ?Token {
        const start = self.pos;

        while (self.pos < self.input.len) : (self.pos += 1) {
            if (std.mem.startsWith(u8, self.input[self.pos..], "{{")) {
                if (self.pos > start) {
                    return .{ .text = self.input[start..self.pos] };
                }
                self.pos += 2;

                if (self.consume("#")) return self.section(.section_open, false);
                if (self.consume("^")) return self.section(.section_open, true);
                if (self.consume("/")) return self.section(.section_close, undefined);

                return self.variable();
            }
        }

        if (start < self.pos) {
            return .{ .text = self.input[start..self.pos] };
        }

        return null;
    }

    fn consume(self: *Tokenizer, seq: []const u8) bool {
        if (std.mem.startsWith(u8, self.input[self.pos..], seq)) {
            self.pos += seq.len;
            return true;
        }

        return false;
    }

    fn consumeIdent(self: *Tokenizer) ?[]const u8 {
        const start = self.pos;

        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => self.pos += 1,
                else => break,
            }
        }

        return if (self.pos > start) self.input[start..self.pos] else null;
    }

    fn variable(self: *Tokenizer) ?Token {
        if (self.consumeIdent()) |name| {
            if (self.consume("}}")) {
                return .{ .variable = name };
            }
        }

        return .{ .text = self.input[self.pos - 2 ..] };
    }

    fn section(self: *Tokenizer, tag: Tag, inverted: bool) ?Token {
        if (self.consumeIdent()) |name| {
            if (self.consume("}}")) {
                return switch (tag) {
                    .section_open => .{ .section_open = .{ .name = name, .inverted = inverted } },
                    .section_close => .{ .section_close = name },
                    else => unreachable,
                };
            }
        }

        return .{ .text = self.input[self.pos - 2 ..] };
    }
};

fn expectTokens(tpl: []const u8, tokens: []const Tag) !void {
    var tokenizer = Tokenizer{ .input = tpl };

    for (tokens) |tag| {
        const tok: Tag = tokenizer.next() orelse return error.Eof;
        errdefer std.debug.print("rest: {s}\n", .{tokenizer.input[tokenizer.pos..]});

        try std.testing.expectEqual(tag, tok);
    }

    try std.testing.expectEqual(tpl.len, tokenizer.pos);
}

test "Tokenizer" {
    try expectTokens("", &.{});

    try expectTokens("Hello", &.{.text});
    try expectTokens("{{name}}", &.{.variable});
    try expectTokens("{{#name}}", &.{.section_open});
    try expectTokens("{{^name}}", &.{.section_open});
    try expectTokens("{{/name}}", &.{.section_close});

    try expectTokens("Hello {{name}}", &.{ .text, .variable });
    try expectTokens("{{#name}}{{/name}}", &.{ .section_open, .section_close });
}
