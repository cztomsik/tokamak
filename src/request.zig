const std = @import("std");

pub const Request = struct {
    allocator: std.mem.Allocator,
    raw: std.http.Server.Request,
    method: std.http.Method,
    path: []const u8,
    query_params: []const QueryParam,

    pub const QueryParam = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, raw: std.http.Server.Request) !Request {
        const target: []u8 = try allocator.dupe(u8, raw.head.target);
        const i = std.mem.indexOfScalar(u8, target, '?') orelse target.len;

        return .{
            .allocator = allocator,
            .raw = raw,
            .method = raw.head.method,
            .path = decodeInplace(target[0..i]),
            .query_params = if (i < target.len) try parseQueryParams(allocator, target[i + 1 ..]) else &.{},
        };
    }

    /// Returns the value of the given query parameter or null if it doesn't
    /// exist.
    pub fn getQueryParam(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.query_params) |param| {
            if (std.mem.eql(u8, param.name, name)) {
                return param.value;
            }
        }

        return null;
    }

    /// Returns the value of the given header or null if it doesn't exist.
    pub fn getHeader(self: *Request, name: []const u8) ?[]const u8 {
        var it = self.raw.iterateHeaders();

        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }

        return null;
    }

    /// Returns the value of the given cookie or null if it doesn't exist.
    pub fn getCookie(self: *Request, name: []const u8) ?[]const u8 {
        const header = self.getHeader("cookie") orelse return null;

        var it = std.mem.splitSequence(u8, header, "; ");

        while (it.next()) |part| {
            const i = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const key = part[0..i];
            const value = part[i + 1 ..];

            if (std.mem.eql(u8, key, name)) return value;
        }

        return null;
    }

    /// Tries to match the request path against the given pattern and returns
    /// the parsed parameters.
    pub fn match(self: *const Request, pattern: []const u8) ?Params {
        return Params.match(pattern, self.path);
    }

    /// Reads the query parameters into a struct.
    pub fn readQuery(self: *const Request, comptime T: type) !T {
        var res: T = undefined;

        inline for (@typeInfo(T).Struct.fields) |f| {
            if (self.getQueryParam(f.name)) |param| {
                @field(res, f.name) = try parse(f.type, param);
            } else if (f.default_value) |ptr| {
                @field(res, f.name) = @as(*const f.type, @ptrCast(@alignCast(ptr))).*;
            } else {
                return error.MissingField;
            }
        }

        return res;
    }

    /// Reads the request body as JSON.
    pub fn readJson(self: *Request, comptime T: type) !T {
        var reader = std.json.reader(self.allocator, try self.raw.reader());

        return std.json.parseFromTokenSourceLeaky(
            T,
            self.allocator,
            &reader,
            .{ .ignore_unknown_fields = true },
        );
    }

    fn parseQueryParams(allocator: std.mem.Allocator, query: []u8) ![]const QueryParam {
        const res = try allocator.alloc(QueryParam, std.mem.count(u8, query, "&") + 1);
        var i: usize = 0;

        for (res) |*p| {
            const part = query[i .. std.mem.indexOfScalarPos(u8, query, i, '&') orelse query.len];
            const eq = std.mem.indexOfScalar(u8, part, '=');

            p.name = decodeInplace(part[0 .. eq orelse part.len]);
            p.value = if (eq) |j| decodeInplace(part[j + 1 ..]) else "";

            i += part.len;
            if (i < query.len) i += 1;
        }

        return res;
    }

    fn decodeInplace(buf: []u8) []u8 {
        std.mem.replaceScalar(u8, buf, '+', ' ');
        return std.Uri.percentDecodeInPlace(buf);
    }
};

fn fakeReq(arena: *std.heap.ArenaAllocator, input: []const u8) !Request {
    const bytes = try arena.allocator().dupe(u8, input);

    var server: std.http.Server = undefined;
    server.read_buffer = bytes;

    return Request.init(
        arena.allocator(),
        std.http.Server.Request{
            .server = &server,
            .head = try std.http.Server.Request.Head.parse(bytes),
            .head_end = bytes.len,
            .reader_state = undefined,
        },
    );
}

test "request parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req1 = try fakeReq(&arena, "GET /test HTTP/1.0\r\n\r\n");
    const req2 = try fakeReq(&arena, "POST /foo%20bar HTTP/1.0\r\n\r\n");
    const req3 = try fakeReq(&arena, "PUT /foo%3Abar+baz HTTP/1.0\r\n\r\n");
    const req4 = try fakeReq(&arena, "DELETE /test?foo=hello%20world&bar=baz%3Aqux&opt=null HTTP/1.0\r\n\r\n");

    try std.testing.expectEqual(std.http.Method.GET, req1.method);
    try std.testing.expectEqual(std.http.Method.POST, req2.method);
    try std.testing.expectEqual(std.http.Method.PUT, req3.method);
    try std.testing.expectEqual(std.http.Method.DELETE, req4.method);

    try std.testing.expectEqualStrings("/test", req1.path);
    try std.testing.expectEqualStrings("/foo bar", req2.path);
    try std.testing.expectEqualStrings("/foo:bar baz", req3.path);
    try std.testing.expectEqualStrings("/test", req4.path);

    try std.testing.expectEqualStrings("hello world", req4.getQueryParam("foo").?);
    try std.testing.expectEqualStrings("baz:qux", req4.getQueryParam("bar").?);
    try std.testing.expectEqualStrings("null", req4.getQueryParam("opt").?);
    try std.testing.expectEqual(null, req4.getQueryParam("missing"));
}

test "req.getHeader()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try fakeReq(&arena, "GET /test HTTP/1.0\r\nFoo: bar\r\n\r\n");

    try std.testing.expectEqualStrings("bar", req.getHeader("foo").?);
    try std.testing.expectEqual(null, req.getHeader("missing"));
}

test "req.getCookie()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try fakeReq(&arena, "GET /test HTTP/1.0\r\nCookie: foo=bar; baz=qux\r\n\r\n");

    try std.testing.expectEqualStrings("bar", req.getCookie("foo").?);
    try std.testing.expectEqualStrings("qux", req.getCookie("baz").?);
    try std.testing.expectEqual(null, req.getCookie("missing"));
}

test "req.readQuery()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try fakeReq(&arena, "GET /test?str=foo&num=123&opt=null HTTP/1.0\r\n\r\n");

    const q1 = try req.readQuery(struct { str: []const u8, num: u32, opt: ?u32 });
    try std.testing.expectEqualStrings("foo", q1.str);
    try std.testing.expectEqual(123, q1.num);
    try std.testing.expectEqual(null, q1.opt);

    const q2 = try req.readQuery(struct { missing: ?u32 = null, opt: ?u32 });
    try std.testing.expectEqual(null, q2.missing);
    try std.testing.expectEqual(null, q2.opt);

    const q3 = try req.readQuery(struct { num: u32 = 0, missing: u32 = 123 });
    try std.testing.expectEqual(123, q3.num);
    try std.testing.expectEqual(123, q3.missing);
}

pub const Params = struct {
    matches: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn match(pattern: []const u8, path: []const u8) ?Params {
        var res = Params{};
        var pattern_parts = std.mem.tokenizeScalar(u8, pattern, '/');
        var path_parts = std.mem.tokenizeScalar(u8, path, '/');

        while (true) {
            const pat = pattern_parts.next() orelse return if (pattern[pattern.len - 1] == '*' or path_parts.next() == null) res else null;
            const pth = path_parts.next() orelse return null;
            const dynamic = pat[0] == ':' or pat[0] == '*';

            if (std.mem.indexOfScalar(u8, pat, '.')) |i| {
                const j = (if (dynamic) std.mem.lastIndexOfScalar(u8, pth, '.') else std.mem.indexOfScalar(u8, pth, '.')) orelse return null;

                if (match(pat[i + 1 ..], pth[j + 1 ..])) |ch| {
                    for (ch.matches, res.len..) |s, l| res.matches[l] = s;
                    res.len += ch.len;
                } else return null;
            }

            if (!dynamic and !std.mem.eql(u8, pat, pth)) return null;

            if (pat[0] == ':') {
                res.matches[res.len] = pth;
                res.len += 1;
            }
        }
    }

    pub fn get(self: *const Params, index: usize, comptime T: type) !T {
        if (index >= self.len) return error.NoMatch;

        return parse(T, self.matches[index]);
    }
};

fn parse(comptime T: type, s: []const u8) !T {
    return switch (@typeInfo(T)) {
        .Optional => |o| if (std.mem.eql(u8, s, "null")) null else try parse(o.child, s),
        .Int => std.fmt.parseInt(T, s, 10),
        .Enum => std.meta.stringToEnum(T, s) orelse error.InvalidEnumTag,
        else => s,
    };
}

fn expectMatch(pattern: []const u8, path: []const u8, len: usize) !void {
    if (Params.match(pattern, path)) |m| {
        try std.testing.expectEqual(m.len, len);
    } else return error.ExpectedMatch;
}

test "Params matching" {
    try expectMatch("/", "/", 0);
    // TODO: fix this, but we need more tests first
    // try expectMatch("/*", "/", 0);
    try expectMatch("/*", "/foo", 0);
    try expectMatch("/*", "/foo/bar", 0);
    try expectMatch("/*.js", "/foo.js", 0);
    try expectMatch("/foo", "/foo", 0);
    try expectMatch("/:foo", "/foo", 1);
    try expectMatch("/:foo/bar", "/foo/bar", 1);
}
