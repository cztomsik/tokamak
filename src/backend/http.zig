const std = @import("std");

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    query: std.StringHashMapUnmanaged([]const u8) = .empty,
    arena: std.mem.Allocator,
    native: *anyopaque,
    body_fn: *const fn (*anyopaque) anyerror!?[]const u8,
    header_fn: *const fn (*anyopaque, []const u8) ?[]const u8,

    pub fn body(self: *Request) !?[]const u8 {
        return self.body_fn(self.native);
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.header_fn(self.native, name);
    }

    pub fn queryGet(self: *const Request, name: []const u8) ?[]const u8 {
        return self.query.get(name);
    }
};

pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "",
    content_type: ?ContentType = null,
    native: *anyopaque,
    header_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    stream_fn: *const fn (*anyopaque) anyerror!EventStream,
    streaming: bool = false,

    pub const ContentType = enum { text, json, html };

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        if (name.len == 0) return error.InvalidHeader;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidHeader;
        }
        for (value) |c| {
            if (c < 0x20 and c != '\t' or c == 0x7f) return error.InvalidHeader;
        }
        try self.header_fn(self.native, name, value);
    }

    pub fn startEventStream(self: *Response) !EventStream {
        const stream = try self.stream_fn(self.native);
        self.streaming = true;
        return stream;
    }
};

pub const EventStream = struct {
    native: *anyopaque,
    send_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    end_fn: *const fn (*anyopaque) void,

    pub fn send(self: *EventStream, data: []const u8) !void {
        try self.send_fn(self.native, data);
    }

    pub fn end(self: *EventStream) void {
        self.end_fn(self.native);
    }
};
