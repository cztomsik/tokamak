const std = @import("std");
const Request = @import("request.zig").Request;

pub const Response = struct {
    req: *Request,
    responded: bool = false,
    keep_alive: bool = true,
    sse: bool = false,
    status: std.http.Status = .ok,
    headers: std.ArrayList(std.http.Header),
    out: ?std.http.Server.Response = null,
    buf: [1024]u8 = undefined,

    /// Sets a header. If the response has already been sent, this function
    /// returns an error. Both `name` and `value` must be valid for the entire
    /// lifetime of the response.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.responded) return error.HeadersAlreadySent;

        try self.headers.append(.{ .name = name, .value = value });
    }

    /// Sets a cookie. If the response has already been sent, this function
    /// returns an error.
    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, options: CookieOptions) !void {
        if (self.responded) return error.HeadersAlreadySent;

        // TODO: start with current header?
        var buf = std.ArrayList(u8).init(self.req.allocator);

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

    /// Returns a writer for the response body. If the response has already been
    /// sent, this function returns an error.
    pub fn writer(self: *Response) !std.io.AnyWriter {
        if (!self.responded) try self.respond();
        return self.out.?.writer();
    }

    /// Sends a response depending on the type of the value.
    pub fn send(self: *Response, res: anytype) !void {
        if (comptime @TypeOf(res) == []const u8) return self.sendChunk(res);

        return switch (comptime @typeInfo(@TypeOf(res))) {
            .Void => if (!self.responded) self.sendStatus(.no_content),
            .ErrorSet => self.sendError(res),
            .ErrorUnion => if (res) |r| self.send(r) else |e| self.sendError(e),
            else => self.sendJson(res),
        };
    }

    /// Sends a status code.
    pub fn sendStatus(self: *Response, status: std.http.Status) !void {
        self.status = status;
        try self.respond();
    }

    /// Sends an error response.
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

    /// Sends a chunk of data.
    pub fn sendChunk(self: *Response, chunk: []const u8) !void {
        var w = try self.writer();
        try w.writeAll(chunk);
        try self.out.?.flush();
    }

    /// Sends a chunk of JSON. The chunk is always either single line, or in
    /// case of SSE, it's a valid message ending with \n\n.
    /// Supports values, slices and iterators.
    pub fn sendJson(self: *Response, body: anytype) !void {
        if (!self.responded) {
            try self.setHeader("Content-Type", "application/json");
        }

        var w = try self.writer();

        if (self.sse) {
            try w.writeAll("data: ");
        }

        if (comptime std.meta.hasFn(@TypeOf(body), "next")) {
            var copy = body;
            var i: usize = 0;

            try w.writeAll("[");
            while (try copy.next()) |item| : (i += 1) {
                if (i != 0) try w.writeAll(",");
                try std.json.stringify(item, .{}, w);
            }
            try w.writeAll("]");
        } else {
            try std.json.stringify(body, .{}, w);
        }

        try w.writeAll(if (self.sse) "\n\n" else "\r\n");
        try self.out.?.flush();
    }

    /// Sends a chunk of JSON lines. The chunk always ends with a newline.
    /// Expects an iterator.
    pub fn sendJsonLines(self: *Response, iterator: anytype) !void {
        if (!self.responded) {
            try self.setHeader("Content-Type", "application/jsonlines");
            try self.respond();
        }

        var copy = iterator;
        while (try copy.next()) |item| {
            try self.sendJson(item);
        }
    }

    /// Starts an SSE stream.
    pub fn startSse(self: *Response) !void {
        try self.setHeader("Content-Type", "text/event-stream");
        try self.setHeader("Cache-Control", "no-cache");
        try self.setHeader("Connection", "keep-alive");

        self.sse = true;
        try self.respond();
    }

    /// Redirects the response to a different URL.
    pub fn redirect(self: *Response, url: []const u8, options: struct { status: std.http.Status = .found }) !void {
        try self.setHeader("Location", url);
        try self.sendStatus(options.status);
    }

    /// Adds no-cache headers to the response.
    pub fn noCache(self: *Response) !void {
        try self.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
        try self.setHeader("Pragma", "no-cache");
        try self.setHeader("Expires", "0");
    }

    /// Start the response manually.
    pub fn respond(self: *Response) !void {
        if (self.responded) return error.ResponseAlreadyStarted;

        self.responded = true;
        self.out = self.req.raw.respondStreaming(.{
            .send_buffer = &self.buf,
            .respond_options = .{
                .status = self.status,
                .keep_alive = self.keep_alive,
                .extra_headers = self.headers.items,
            },
        });
    }
};

pub const CookieOptions = struct {
    domain: ?[]const u8 = null,
    max_age: ?u32 = null,
    http_only: bool = false,
    secure: bool = false,
};
