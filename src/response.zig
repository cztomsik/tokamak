const builtin = @import("builtin");
const root = @import("root");
const std = @import("std");
const mime = @import("mime.zig").mime;
const Request = @import("request.zig").Request;

pub const Response = struct {
    req: *Request,
    responded: bool = false,
    keep_alive: bool = true,
    status: std.http.Status = .ok,
    headers: std.ArrayList(std.http.Header),
    out: ?std.http.Server.Response = null,
    buf: [1024]u8 = undefined,

    pub fn init(req: *Request) Response {
        return .{
            .req = req,
            .headers = std.ArrayList(std.http.Header).init(req.allocator),
        };
    }

    /// Sets a header. If the response has already been sent, this function
    /// returns an error.
    pub fn setHeader(self: *Response, comptime name: []const u8, value: []const u8) !void {
        if (self.responded) return error.HeadersAlreadySent;

        const v = try self.req.allocator.dupe(u8, value);
        errdefer self.req.allocator.free(v);

        try self.headers.append(.{ .name = name, .value = v });
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
            .Void => if (!self.responded) self.noContent(),
            .ErrorUnion => if (res) |r| self.send(r) else |e| self.sendError(e),
            else => self.sendJson(res),
        };
    }

    /// Sends an error response.
    pub fn sendError(self: *Response, err: anyerror) !void {
        self.status = switch (err) {
            error.NotFound => .not_found,
            // inline std.json.ParseFromValueError => .bad_request,
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

    /// Sends a chunk of JSON. The chunk always ends with a newline.
    /// Supports values, slices and iterators.
    pub fn sendJson(self: *Response, body: anytype) !void {
        if (!self.responded) {
            try self.setHeader("Content-Type", "application/json");
        }

        var w = try self.writer();

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

        try w.writeAll("\r\n");
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

    /// Sends a static resource. The resource is embedded in release builds.
    pub fn sendResource(self: *Response, comptime path: []const u8) !void {
        try self.setHeader("Content-Type", comptime mime(std.fs.path.extension(path)) ++ "; charset=utf-8");
        try self.noCache();

        try self.sendChunk(if (comptime builtin.mode != .Debug) root.embedFile(path) else blk: {
            var f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            break :blk try f.readToEndAlloc(self.req.allocator, std.math.maxInt(usize));
        });
    }

    /// Sends a 404 response.
    pub fn notFound(self: *Response) !void {
        self.status = .not_found;
        try self.respond();
    }

    /// Sends an empty response.
    pub fn noContent(self: *Response) !void {
        self.status = .no_content;
        try self.respond();
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
