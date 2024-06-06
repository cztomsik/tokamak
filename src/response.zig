const std = @import("std");
const Request = @import("request.zig").Request;

/// Server response.
pub const Response = struct {
    status: ?std.http.Status = null,
    headers: std.ArrayList(std.http.Header),
    body: union(enum) {
        slice: []const u8,
        stream: std.io.AnyReader,
    } = .{ .slice = "" },
    keep_alive: bool = false,

    /// Sets a header. Both `name` and `value` must be valid for the entire
    /// lifetime of the response.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.append(.{ .name = name, .value = value });
    }

    /// Sets a cookie.
    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, options: CookieOptions) !void {
        // TODO: start with current header?
        var buf = std.ArrayList(u8).init(self.headers.allocator);

        try buf.appendSlice(name);
        try buf.append('=');
        try buf.appendSlice(value);

        if (options.max_age) |age| {
            try buf.appendSlice("; Max-Age=");
            try buf.writer().print("{d}", .{age});
        }

        if (options.domain) |d| {
            try buf.appendSlice("; Domain=");
            try buf.appendSlice(d);
        }

        if (options.http_only) {
            try buf.appendSlice("; HttpOnly");
        }

        if (options.secure) {
            try buf.appendSlice("; Secure");
        }

        try self.setHeader("Set-Cookie", buf.items);
    }

    /// Sends a response depending on the type of the value.
    pub fn send(self: *Response, res: anytype) !void {
        return switch (@TypeOf(res)) {
            []const u8 => self.sendText(res),
            else => |T| switch (@typeInfo(T)) {
                .Void => if (self.status == null) {
                    self.status = .no_content;
                    self.body = .{ .slice = "" };
                },
                .ErrorSet => self.sendError(res),
                .ErrorUnion => if (res) |r| self.send(r) else |e| self.sendError(e),
                else => self.sendJson(res),
            },
        };
    }

    /// Sends an error response with an appropriate HTTP status.
    pub fn sendError(self: *Response, err: anyerror) !void {
        self.status = switch (err) {
            error.InvalidCharacter, error.UnexpectedToken, error.InvalidNumber, error.Overflow, error.InvalidEnumTag, error.DuplicateField, error.UnknownField, error.MissingField, error.LengthMismatch => .bad_request,
            error.Unauthorized => .unauthorized,
            error.NotFound => .not_found,
            error.Forbidden => .forbidden,
            else => .internal_server_error,
        };

        return self.sendJson(.{ .@"error" = err });
    }

    /// Sends a text response.
    pub fn sendText(self: *Response, text: []const u8) !void {
        if (self.status == null) self.status = .ok;

        try self.setHeader("Content-Type", "text/plain; charset=utf-8");

        self.body = .{ .slice = text };
    }

    /// Sends a JSON response.
    pub fn sendJson(self: *Response, data: anytype) !void {
        if (self.status == null) self.status = .ok;

        try self.setHeader("Content-Type", "application/json; charset=utf-8");

        self.body = .{
            .slice = try std.json.stringifyAlloc(self.headers.allocator, data, .{}),
        };
    }

    /// Redirects the client to a different URL with an optional status code.
    pub fn redirect(self: *Response, url: []const u8, options: struct { status: std.http.Status = .found }) !void {
        self.status = options.status;

        try self.setHeader("Location", url);
    }

    /// Adds headers to prevent caching of the response.
    pub fn noCache(self: *Response) !void {
        try self.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
        try self.setHeader("Pragma", "no-cache");
        try self.setHeader("Expires", "0");
    }

    // Internal
    pub fn writeHead(self: *Response, writer: anytype) !void {
        const status = self.status orelse return error.InvalidState;

        try writer.print("HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(status),
            status.phrase() orelse "",
        });

        for (self.headers.items) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        try switch (self.body) {
            .slice => |data| writer.print("Content-Length: {d}\r\n", .{data.len}),
            .stream => writer.print("Transfer-Encoding: chunked\r\n", .{}),
        };

        if (!self.keep_alive) {
            try writer.print("Connection: close\r\n", .{});
        }

        try writer.print("\r\n", .{});
    }
};

pub const CookieOptions = struct {
    domain: ?[]const u8 = null,
    max_age: ?u32 = null,
    http_only: bool = false,
    secure: bool = false,
};
