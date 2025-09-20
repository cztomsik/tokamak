const std = @import("std");

pub fn Decoder(comptime entities: anytype) type {
    @setEvalBranchQuota(5000);
    const map = std.StaticStringMap([]const u8).initComptime(entities);

    return struct {
        input: []const u8,
        pos: usize = 0,
        buf: [4]u8 = undefined,

        pub fn init(input: []const u8) @This() {
            return .{ .input = input };
        }

        pub fn next(self: *@This()) ?[]const u8 {
            if (self.pos >= self.input.len) {
                return null;
            }

            if (self.input[self.pos] == '&') {
                if (self.findEnd()) |end| {
                    defer self.pos = end + 1;
                    return self.decodeEntity(self.input[self.pos..end]) orelse self.input[self.pos .. end + 1];
                }
            }

            if (std.mem.indexOfScalarPos(u8, self.input, self.pos + 1, '&')) |start| {
                defer self.pos = start;
                return self.input[self.pos..start];
            }

            defer self.pos = self.input.len;
            return self.input[self.pos..];
        }

        fn findEnd(self: *@This()) ?usize {
            var i = self.pos + 1;
            while (i < self.input.len) : (i += 1) {
                switch (self.input[i]) {
                    ';' => return i,
                    ' ', '\t', '\r', '\n', '<', '&' => return null,
                    else => {},
                }
            } else return null;
        }

        pub fn decodeEntity(self: *@This(), entity: []const u8) ?[]const u8 {
            if (entity.len > 3 and entity[1] == '#') {
                const num = if (entity[2] == 'x')
                    std.fmt.parseInt(u21, entity[3..], 16)
                else
                    std.fmt.parseInt(u21, entity[2..], 10);

                if (num catch null) |cp| {
                    return self.buf[0 .. std.unicode.utf8Encode(cp, &self.buf) catch 0];
                }
            }

            return map.get(entity);
        }
    };
}

pub fn decode(allocator: std.mem.Allocator, input: []const u8, comptime entities: anytype) ![]const u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var it = Decoder(entities).init(input);
    while (it.next()) |chunk| {
        try buf.appendSlice(allocator, chunk);
    }

    return buf.toOwnedSlice(allocator);
}

pub fn decodeInplace(buf: []u8, comptime entities: anytype) []u8 {
    var decoder = Decoder(entities).init(buf);
    var len: usize = 0;
    while (decoder.next()) |chunk| {
        std.mem.copyForwards(u8, buf[len .. len + chunk.len], chunk);
        len += chunk.len;
    }
    return buf[0..len];
}

pub const xml = .{
    .{ "&amp", "&" },
    .{ "&lt", "<" },
    .{ "&gt", ">" },
    .{ "&quot", "\"" },
    .{ "&apos", "'" },
};

pub const html4 = xml ++ .{
    .{ "&apos", "'" },
    .{ "&nbsp", " " },
    .{ "&iexcl", "¡" },
    .{ "&cent", "¢" },
    .{ "&pound", "£" },
    .{ "&curren", "¤" },
    .{ "&yen", "¥" },
    .{ "&brvbar", "¦" },
    .{ "&sect", "§" },
    .{ "&uml", "¨" },
    .{ "&copy", "©" },
    .{ "&ordf", "ª" },
    .{ "&laquo", "«" },
    .{ "&not", "¬" },
    .{ "&shy", "­" },
    .{ "&reg", "®" },
    .{ "&macr", "¯" },
    .{ "&deg", "°" },
    .{ "&plusmn", "±" },
    .{ "&sup2", "²" },
    .{ "&sup3", "³" },
    .{ "&acute", "´" },
    .{ "&micro", "µ" },
    .{ "&para", "¶" },
    .{ "&middot", "·" },
    .{ "&cedil", "¸" },
    .{ "&sup1", "¹" },
    .{ "&ordm", "º" },
    .{ "&raquo", "»" },
    .{ "&frac14", "¼" },
    .{ "&frac12", "½" },
    .{ "&frac34", "¾" },
    .{ "&iquest", "¿" },
    .{ "&Agrave", "À" },
    .{ "&Aacute", "Á" },
    .{ "&Acirc", "Â" },
    .{ "&Atilde", "Ã" },
    .{ "&Auml", "Ä" },
    .{ "&Aring", "Å" },
    .{ "&AElig", "Æ" },
    .{ "&Ccedil", "Ç" },
    .{ "&Egrave", "È" },
    .{ "&Eacute", "É" },
    .{ "&Ecirc", "Ê" },
    .{ "&Euml", "Ë" },
    .{ "&Igrave", "Ì" },
    .{ "&Iacute", "Í" },
    .{ "&Icirc", "Î" },
    .{ "&Iuml", "Ï" },
    .{ "&ETH", "Ð" },
    .{ "&Ntilde", "Ñ" },
    .{ "&Ograve", "Ò" },
    .{ "&Oacute", "Ó" },
    .{ "&Ocirc", "Ô" },
    .{ "&Otilde", "Õ" },
    .{ "&Ouml", "Ö" },
    .{ "&times", "×" },
    .{ "&Oslash", "Ø" },
    .{ "&Ugrave", "Ù" },
    .{ "&Uacute", "Ú" },
    .{ "&Ucirc", "Û" },
    .{ "&Uuml", "Ü" },
    .{ "&Yacute", "Ý" },
    .{ "&THORN", "Þ" },
    .{ "&szlig", "ß" },
    .{ "&agrave", "à" },
    .{ "&aacute", "á" },
    .{ "&acirc", "â" },
    .{ "&atilde", "ã" },
    .{ "&auml", "ä" },
    .{ "&aring", "å" },
    .{ "&aelig", "æ" },
    .{ "&ccedil", "ç" },
    .{ "&egrave", "è" },
    .{ "&eacute", "é" },
    .{ "&ecirc", "ê" },
    .{ "&euml", "ë" },
    .{ "&igrave", "ì" },
    .{ "&iacute", "í" },
    .{ "&icirc", "î" },
    .{ "&iuml", "ï" },
    .{ "&eth", "ð" },
    .{ "&ntilde", "ñ" },
    .{ "&ograve", "ò" },
    .{ "&oacute", "ó" },
    .{ "&ocirc", "ô" },
    .{ "&otilde", "õ" },
    .{ "&ouml", "ö" },
    .{ "&divide", "÷" },
    .{ "&oslash", "ø" },
    .{ "&ugrave", "ù" },
    .{ "&uacute", "ú" },
    .{ "&ucirc", "û" },
    .{ "&uuml", "ü" },
    .{ "&yacute", "ý" },
    .{ "&thorn", "þ" },
    .{ "&yuml", "ÿ" },
    .{ "&quot", "\"" },
    .{ "&amp", "&" },
    .{ "&lt", "<" },
    .{ "&gt", ">" },
    .{ "&OElig", "Œ" },
    .{ "&oelig", "œ" },
    .{ "&Scaron", "Š" },
    .{ "&scaron", "š" },
    .{ "&Yuml", "Ÿ" },
    .{ "&circ", "ˆ" },
    .{ "&tilde", "˜" },
    .{ "&ensp", " " },
    .{ "&emsp", " " },
    .{ "&thinsp", " " },
    .{ "&zwnj", "‌" },
    .{ "&zwj", "‍" },
    .{ "&lrm", "‎" },
    .{ "&rlm", "‏" },
    .{ "&ndash", "–" },
    .{ "&mdash", "—" },
    .{ "&lsquo", "‘" },
    .{ "&rsquo", "’" },
    .{ "&sbquo", "‚" },
    .{ "&ldquo", "“" },
    .{ "&rdquo", "”" },
    .{ "&bdquo", "„" },
    .{ "&dagger", "†" },
    .{ "&Dagger", "‡" },
    .{ "&permil", "‰" },
    .{ "&lsaquo", "‹" },
    .{ "&rsaquo", "›" },
    .{ "&euro", "€" },
    .{ "&fnof", "ƒ" },
    .{ "&Alpha", "Α" },
    .{ "&Beta", "Β" },
    .{ "&Gamma", "Γ" },
    .{ "&Delta", "Δ" },
    .{ "&Epsilon", "Ε" },
    .{ "&Zeta", "Ζ" },
    .{ "&Eta", "Η" },
    .{ "&Theta", "Θ" },
    .{ "&Iota", "Ι" },
    .{ "&Kappa", "Κ" },
    .{ "&Lambda", "Λ" },
    .{ "&Mu", "Μ" },
    .{ "&Nu", "Ν" },
    .{ "&Xi", "Ξ" },
    .{ "&Omicron", "Ο" },
    .{ "&Pi", "Π" },
    .{ "&Rho", "Ρ" },
    .{ "&Sigma", "Σ" },
    .{ "&Tau", "Τ" },
    .{ "&Upsilon", "Υ" },
    .{ "&Phi", "Φ" },
    .{ "&Chi", "Χ" },
    .{ "&Psi", "Ψ" },
    .{ "&Omega", "Ω" },
    .{ "&alpha", "α" },
    .{ "&beta", "β" },
    .{ "&gamma", "γ" },
    .{ "&delta", "δ" },
    .{ "&epsilon", "ε" },
    .{ "&zeta", "ζ" },
    .{ "&eta", "η" },
    .{ "&theta", "θ" },
    .{ "&iota", "ι" },
    .{ "&kappa", "κ" },
    .{ "&lambda", "λ" },
    .{ "&mu", "μ" },
    .{ "&nu", "ν" },
    .{ "&xi", "ξ" },
    .{ "&omicron", "ο" },
    .{ "&pi", "π" },
    .{ "&rho", "ρ" },
    .{ "&sigmaf", "ς" },
    .{ "&sigma", "σ" },
    .{ "&tau", "τ" },
    .{ "&upsilon", "υ" },
    .{ "&phi", "φ" },
    .{ "&chi", "χ" },
    .{ "&psi", "ψ" },
    .{ "&omega", "ω" },
    .{ "&thetasym", "ϑ" },
    .{ "&upsih", "ϒ" },
    .{ "&piv", "ϖ" },
    .{ "&bull", "•" },
    .{ "&hellip", "…" },
    .{ "&prime", "′" },
    .{ "&Prime", "″" },
    .{ "&oline", "‾" },
    .{ "&frasl", "⁄" },
    .{ "&weierp", "℘" },
    .{ "&image", "ℑ" },
    .{ "&real", "ℜ" },
    .{ "&trade", "™" },
    .{ "&alefsym", "ℵ" },
    .{ "&larr", "←" },
    .{ "&uarr", "↑" },
    .{ "&rarr", "→" },
    .{ "&darr", "↓" },
    .{ "&harr", "↔" },
    .{ "&crarr", "↵" },
    .{ "&lArr", "⇐" },
    .{ "&uArr", "⇑" },
    .{ "&rArr", "⇒" },
    .{ "&dArr", "⇓" },
    .{ "&hArr", "⇔" },
    .{ "&forall", "∀" },
    .{ "&part", "∂" },
    .{ "&exist", "∃" },
    .{ "&empty", "∅" },
    .{ "&nabla", "∇" },
    .{ "&isin", "∈" },
    .{ "&notin", "∉" },
    .{ "&ni", "∋" },
    .{ "&prod", "∏" },
    .{ "&sum", "∑" },
    .{ "&minus", "−" },
    .{ "&lowast", "∗" },
    .{ "&radic", "√" },
    .{ "&prop", "∝" },
    .{ "&infin", "∞" },
    .{ "&ang", "∠" },
    .{ "&and", "∧" },
    .{ "&or", "∨" },
    .{ "&cap", "∩" },
    .{ "&cup", "∪" },
    .{ "&int", "∫" },
    .{ "&there4", "∴" },
    .{ "&sim", "∼" },
    .{ "&cong", "≅" },
    .{ "&asymp", "≈" },
    .{ "&ne", "≠" },
    .{ "&equiv", "≡" },
    .{ "&le", "≤" },
    .{ "&ge", "≥" },
    .{ "&sub", "⊂" },
    .{ "&sup", "⊃" },
    .{ "&nsub", "⊄" },
    .{ "&sube", "⊆" },
    .{ "&supe", "⊇" },
    .{ "&oplus", "⊕" },
    .{ "&otimes", "⊗" },
    .{ "&perp", "⊥" },
    .{ "&sdot", "⋅" },
    .{ "&lceil", "⌈" },
    .{ "&rceil", "⌉" },
    .{ "&lfloor", "⌊" },
    .{ "&rfloor", "⌋" },
    .{ "&lang", "〈" },
    .{ "&rang", "〉" },
    .{ "&loz", "◊" },
    .{ "&spades", "♠" },
    .{ "&clubs", "♣" },
    .{ "&hearts", "♥" },
    .{ "&diams", "♦" },
};

fn expectDecode(input: []const u8, expected: []const u8) !void {
    const actual = try decode(std.testing.allocator, input, html4);
    defer std.testing.allocator.free(actual);

    const buf = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(buf);
    const actual2 = decodeInplace(buf, html4);

    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqualStrings(expected, actual2);
}

test "decoding" {
    try expectDecode("a&b", "a&b");
    try expectDecode("&&amp;", "&&");
    try expectDecode("foo&amp;bar", "foo&bar");
    try expectDecode("foo&nbsp;bar&abc;", "foo bar&abc;");
    try expectDecode("&#39;&#x27;&#1234;", "''Ӓ");
    try expectDecode("&#foo;&#x;", "&#foo;&#x;");
}
