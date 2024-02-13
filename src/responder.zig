const builtin = @import("builtin");
const root = @import("root");
const std = @import("std");
const mime = @import("mime.zig").mime;

pub const Responder = struct {
    res: *std.http.Server.Response,

    /// Shorthand for `res.headers.append()`.
    pub fn setHeader(self: *Responder, key: []const u8, value: []const u8) !void {
        try self.res.headers.append(key, value);
    }

    /// Sends a response depending on the type of the value.
    pub fn send(self: *Responder, res: anytype) !void {
        if (comptime @TypeOf(res) == []const u8) return self.sendChunk(res);

        return switch (comptime @typeInfo(@TypeOf(res))) {
            .Void => if (self.res.state != .responded) self.noContent(),
            .ErrorUnion => if (res) |r| self.send(r) else |e| self.sendError(e),
            else => self.sendJson(res),
        };
    }

    /// Sends an error response.
    pub fn sendError(self: *Responder, err: anyerror) !void {
        self.res.status = switch (err) {
            error.NotFound => .not_found,
            else => .internal_server_error,
        };

        return self.sendJson(.{ .@"error" = err });
    }

    /// Sends a chunk of data. Automatically sets the transfer encoding to
    /// chunked if it hasn't been set yet.
    pub fn sendChunk(self: *Responder, chunk: []const u8) !void {
        if (self.res.state == .waited) {
            self.res.transfer_encoding = .chunked;
            try self.res.send();
        }

        // Response.write() will always write all of the data when the transfer
        // encoding is chunked
        _ = try self.res.write(chunk);
    }

    /// Sends a chunk of JSON. The chunk always ends with a newline.
    /// Supports values, slices and iterators.
    pub fn sendJson(self: *Responder, body: anytype) !void {
        if (self.res.state == .waited) {
            try self.res.headers.append("Content-Type", "application/json");
        }

        var list = std.ArrayList(u8).init(self.res.allocator);
        var writer = list.writer();
        defer list.deinit();

        if (comptime std.meta.hasFn(@TypeOf(body), "next")) {
            var copy = body;
            var i: usize = 0;

            try writer.writeAll("[");
            while (try copy.next()) |item| : (i += 1) {
                if (i != 0) try writer.writeAll(",");
                try std.json.stringify(item, .{}, writer);
            }
            try writer.writeAll("]");
        } else {
            try std.json.stringify(body, .{}, writer);
        }

        try list.appendSlice("\r\n");
        try self.sendChunk(list.items);
    }

    /// Sends a static resource. The resource is embedded in release builds.
    pub fn sendResource(self: *Responder, comptime path: []const u8) !void {
        try self.res.headers.append("Content-Type", comptime mime(std.fs.path.extension(path)) ++ "; charset=utf-8");
        try self.noCache();

        try self.sendChunk(if (comptime builtin.mode != .Debug) root.embedFile(path) else blk: {
            var f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            break :blk try f.readToEndAlloc(self.res.allocator, std.math.maxInt(usize));
        });
    }

    /// Sends a 404 response.
    pub fn notFound(self: *Responder) !void {
        self.res.status = .not_found;
        try self.res.send();
    }

    /// Sends an empty response.
    pub fn noContent(self: *Responder) !void {
        self.res.status = .no_content;
        try self.res.send();
    }

    /// Adds no-cache headers to the response.
    pub fn noCache(self: *Responder) !void {
        try self.res.headers.append("Cache-Control", "no-cache, no-store, must-revalidate");
        try self.res.headers.append("Pragma", "no-cache");
        try self.res.headers.append("Expires", "0");
    }
};
