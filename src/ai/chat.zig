const std = @import("std");
const meta = @import("../meta.zig");
const schema = @import("../schema.zig");
const serde = @import("../serde.zig");
const util = @import("../util.zig");

const Content = struct {
    type: enum { text, image_url },
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,
};

const ImageUrl = struct {
    url: []const u8,
    detail: enum { low, high },
};

pub const TextOrContents = union(enum) {
    text: []const u8,
    contents: []const Content,

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        switch (self.*) {
            inline else => |v| try serde.serialize(writer, v),
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        return switch (try source.peekNextTokenType()) {
            .string => .{ .text = try std.json.innerParse([]const u8, allocator, source, options) },
            .array_begin => .{ .contents = try std.json.innerParse([]const Content, allocator, source, options) },
            else => error.UnexpectedToken,
        };
    }
};

pub const Request = struct {
    model: []const u8,
    messages: []const Message,
    tools: []const Tool = &.{},
    response_format: ?struct {
        type: []const u8,
    } = null,
    max_completion_tokens: u32 = 256,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const Message = struct {
    role: Role,
    content: ?TextOrContents = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub fn serialize(self: Message, w: anytype) !void {
        var st = try w.beginStruct(Message, 4);
        inline for (std.meta.fields(@This())) |f| {
            if (meta.optional(@field(self, f.name))) |v| {
                try st.field(f.name, v);
            }
        }
        try st.end();
    }
};

pub const ToolType = enum { function };

pub const Tool = struct {
    type: ToolType = .function,
    function: struct {
        name: []const u8,
        description: ?[]const u8,
        parameters: schema.Schema,
        strict: bool = true, // structured output / grammar
    },

    pub fn tool(name: []const u8, description: ?[]const u8, comptime Args: type) Tool {
        return .{
            .function = .{
                .name = name,
                .description = description,
                .parameters = .forType(Args),
            },
        };
    }
};

pub const ToolCall = struct {
    id: []const u8,
    type: ToolType = .function,
    function: struct {
        name: []const u8,
        arguments: []const u8, // JSON
    },
};

pub const FinishReason = enum {
    stop,
    length,
    function_call,
    tool_calls,
    content_filter,
};

pub const Response = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []const Choice,
    usage: struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    },
    system_fingerprint: ?[]const u8,

    pub fn singleChoice(self: Response) ?Choice {
        return if (self.choices.len == 1) self.choices[0] else null;
    }
};

pub const Choice = struct {
    index: u32,
    message: Message,
    logprobs: ?struct {} = .{},
    finish_reason: FinishReason,

    pub fn text(self: Choice) ?[]const u8 {
        return switch (self.message.content orelse return null) {
            .text => |t| t,
            .contents => |cs| for (cs) |c| {
                if (c.type == .text) return c.text;
            } else null,
        };
    }
};
