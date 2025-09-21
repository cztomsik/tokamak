const std = @import("std");
const dom = @import("dom.zig");

pub const Options = struct {
    em_delim: []const u8 = "*",
    strong_delim: []const u8 = "**",
};

pub fn html2md(allocator: std.mem.Allocator, node: *dom.Node, options: Options) ![]const u8 {
    var aw = std.io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    var md = try Html2Md.init(&aw.writer, options);
    try md.renderNode(node);

    return aw.toOwnedSlice();
}

pub const Html2Md = struct {
    options: Options,
    out: *std.io.Writer,
    in_line: u32 = 0, // <h1>, <tr>
    empty: bool = true,
    pending: union(enum) { nop, sp, br: u2 } = .nop,

    pub fn init(out: *std.io.Writer, options: Options) !Html2Md {
        return .{
            .options = options,
            .out = out,
        };
    }

    pub fn renderNode(self: *Html2Md, node: *dom.Node) !void {
        try node.visit(self);
    }

    pub fn open(self: *Html2Md, element: *dom.Element) !void {
        const p = dom.LocalName.parse;

        try switch (element.local_name) {
            p("br") => self.br(if (self.pending == .br) 2 else 1),
            p("em"), p("i") => self.push(self.options.em_delim),
            p("strong"), p("b") => self.push(self.options.strong_delim),
            p("div") => self.br(1),
            p("p"), p("ul"), p("ol"), p("table") => self.br(2),
            p("h1"), p("h2"), p("h3"), p("h4"), p("h5"), p("h6") => {
                self.br(2);
                self.in_line += 1;
                try self.push("###### "['6' - element.local_name.name()[1] ..]);
            },
            p("th"), p("td") => self.sp(),
            p("tr") => {
                self.br(1);
                self.in_line += 1;
                try self.push("|");
            },
            p("li") => {
                self.br(1);

                if (element.parentElement()) |parent| {
                    if (parent.local_name == p("ol")) {
                        // TODO: Add el.index, it will be useful for nth-child, even/odd
                        var n: usize = 1;
                        var prev = element.previousElementSibling();
                        while (prev) |prevEl| : (prev = prevEl.previousElementSibling()) n += 1;

                        try self.push("");
                        try self.out.print("{d}. ", .{n});
                        return;
                    }
                }

                try self.push("- ");
            },
            else => {},
        };
    }

    pub fn close(self: *Html2Md, element: *dom.Element) !void {
        const p = dom.LocalName.parse;

        try switch (element.local_name) {
            p("em"), p("i") => self.push(self.options.em_delim),
            p("strong"), p("b") => self.push(self.options.strong_delim),
            p("div") => self.br(1),
            p("p"), p("ul"), p("ol"), p("table") => self.br(2),
            p("h1"), p("h2"), p("h3"), p("h4"), p("h5"), p("h6") => {
                self.in_line -|= 1;
                self.br(2);
            },
            p("li") => {
                self.br(1);
                // self.indent -|= 1;
            },
            p("tr") => {
                self.in_line -|= 1;
                self.br(1);
            },
            p("th"), p("td") => {
                self.sp();
                try self.push("|");
            },
            else => {},
        };
    }

    pub fn text(self: *Html2Md, tn: *dom.Text) !void {
        // Nothing to do
        if (tn.data.len() == 0) return;

        // Trim first
        const orig = tn.data.str();
        const chunk = std.mem.trim(u8, orig, " \t\r\n");

        // Nothing to write but keep the space
        if (chunk.len == 0) return self.sp();

        // There was leading white-space, save it
        if (chunk[0] != orig[0]) self.sp();

        // Write (along with normalized spacing, if there was any)
        try self.push(chunk);

        // There was trailing white-space, save it for next time
        if (chunk[chunk.len - 1] != orig[orig.len - 1]) self.sp();
    }

    pub fn push(self: *Html2Md, chunk: []const u8) !void {
        if (!self.empty and self.pending != .nop) {
            try self.out.writeAll(switch (self.pending) {
                .sp => " ",
                .br => |n| if (n == 1) "\n" else "\n\n",
                .nop => unreachable,
            });
        }

        try self.out.writeAll(chunk);
        self.empty = self.empty and chunk.len == 0;
        self.pending = .nop;
    }

    fn sp(self: *Html2Md) void {
        if (self.pending == .nop) {
            self.pending = .sp;
        }
    }

    fn br(self: *Html2Md, n: u2) void {
        self.pending = if (self.in_line > 0) .sp else .{ .br = switch (self.pending) {
            .nop, .sp => n,
            .br => @max(n, self.pending.br),
        } };
    }
};

fn expectMd(comptime input: []const u8, expected: []const u8) !void {
    var doc = try dom.Document.parseFromSlice(std.testing.allocator, "<test>" ++ input ++ "</test>");
    defer doc.deinit();

    const md = try html2md(std.testing.allocator, &doc.node, .{});
    defer std.testing.allocator.free(md);

    try std.testing.expectEqualStrings(expected, md);
}

test "empty" {
    try expectMd("", "");
    try expectMd(" ", "");
    try expectMd("   \n\t  ", "");
    // TODO: &nbsp; etc. (SAX)
}

test "inline" {
    try expectMd("hello world", "hello world");
    // try expectMd("  hello   world  ", "hello world");
    try expectMd("<em>italic</em>", "*italic*");
    try expectMd("<i>italic</i>", "*italic*");
    try expectMd("<strong>bold</strong>", "**bold**");
    try expectMd("<b>bold</b>", "**bold**");
    try expectMd("<em>italic <strong>bold</strong></em>", "*italic **bold***");
}

test "line breaks" {
    try expectMd("line1<br>line2<br/>line3<br />", "line1\nline2\nline3");
    try expectMd("line1 <br><br><br> line2", "line1\n\nline2");
}

test "headings" {
    try expectMd("<h1>Heading 1</h1>", "# Heading 1");
    try expectMd("<h2>Heading 2</h2>", "## Heading 2");
    try expectMd("<h3>Heading 3</h3>", "### Heading 3");
    try expectMd("<h4>Heading 4</h4>", "#### Heading 4");
    try expectMd("<h5>Heading 5</h5>", "##### Heading 5");
    try expectMd("<h6>Heading 6</h6>", "###### Heading 6");

    try expectMd("<h1>First</h1><h2>Second</h2>", "# First\n\n## Second");
    try expectMd("text<h1>Heading</h1>more text", "text\n\n# Heading\n\nmore text");
}

test "divs" {
    try expectMd("<div>content</div>", "content");
    try expectMd("<div>first</div><div>second</div>", "first\nsecond");
}

test "paragraphs" {
    try expectMd("<p>para</p>", "para");
    try expectMd("<p>para</p>text", "para\n\ntext");
    try expectMd("<p>first</p><p>second</p>", "first\n\nsecond");
    try expectMd("text<p>para</p>more", "text\n\npara\n\nmore");
}

test "lists" {
    // Unordered
    try expectMd("<ul><li>item</li></ul>", "- item");
    try expectMd("<ul><li>first</li><li>second</li></ul>", "- first\n- second");
    try expectMd("<ul><li>first</li><li>second</li><li>third</li></ul>", "- first\n- second\n- third");

    // Ordered
    try expectMd("<ol><li>item</li></ol>", "1. item");
    try expectMd("<ol><li>first</li><li>second</li></ol>", "1. first\n2. second");
    try expectMd("<ol><li>first</li><li>second</li><li>third</li></ol>", "1. first\n2. second\n3. third");

    // Nesting
    // try expectMd("<ul><li>parent<ul><li>child</li></ul></li></ul>", "- parent\n  - child");
    // try expectMd("<ol><li>parent<ol><li>child</li></ol></li></ol>", "1. parent\n  1. child");

    // Siblings
    // try expectMd("<ul><li>list1</li></ul><ul><li>list2</li></ul>", "- list1\n\n- list2");
}

test "tables" {
    // TODO: ---
    try expectMd(
        "<table><tr><th>key</th><th>value</th></tr><tr><td>foo</td><td>bar</td></tr><tr><td>baz</td><td>qux</td></tr></table>",
        "| key | value |\n| foo | bar |\n| baz | qux |",
    );

    try expectMd(
        \\<table>
        \\<tr>
        \\  <th>foo</th>
        \\  <th>bar</th>
        \\</tr>
        \\<tr>
        \\  <td>
        \\    <div>baz</div>
        \\  </td>
        \\  <td>
        \\    <div>qux</div>
        \\  </td>
        \\</tr>
        \\</table>
    ,
        "| foo | bar |\n| baz | qux |",
    );
}

test "strip <script>, <style>" {
    try expectMd("<script>foo</script>", "");
    try expectMd("<style>foo</style>", "");
}

// test "uppercase" {
//     try expectMd("<EM>foo</EM>", "*foo*");
//     try expectMd("<STRONG>foo</STRONG>", "**foo**");
// }

test "links and images" {
    // TODO: make this configurable
    try expectMd("<a>foo</a>", "foo");
    try expectMd("<img>", "");
}

test "ignore other" {
    try expectMd("<body>foo</body>", "foo");
    try expectMd("<unknown>foo</unknown>", "foo");
}

test "edge cases" {
    try expectMd("<span>foo</span><span>bar</span>", "foobar");
    try expectMd("<p>foo <span>bar</span></p>", "foo bar");
    // try expectMd("  multiple   spaces  ", "multiple spaces");

    try expectMd("<strong><em>bold italic</em></strong>", "***bold italic***");
    try expectMd("<em><strong>italic bold</strong></em>", "***italic bold***");

    try expectMd("<p></p>", "");
    try expectMd("<strong></strong>", "****");

    try expectMd("<p>foo <span>bar</span> <span>baz</span></p>", "foo bar baz");
    try expectMd("foo <em>bar</em> baz", "foo *bar* baz");
    try expectMd("<span>  foo</span><span>  bar</span>", "foo bar");

    try expectMd("<ul><li>Gymnastick&eacute; &scaron;vihadlo</li></ul>", "- Gymnastické švihadlo");
}
