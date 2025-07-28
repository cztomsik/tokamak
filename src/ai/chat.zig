const std = @import("std");
const schema = @import("../schema.zig");
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

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try switch (self.*) {
            inline else => |v| jw.write(v),
        };
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
    max_tokens: u32 = 256,
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

    pub fn jsonStringify(self: Message, jws: anytype) !void {
        // TODO: this is ugly hack but zig only allows omitting null fields, which is not what we want
        //       (what we want is to omit them only if they also have null as default value)
        try jws.print("{}", .{std.json.fmt(.{
            .role = self.role,
            .content = self.content,
            .tool_calls = self.tool_calls,
            .tool_call_id = self.tool_call_id,
        }, .{ .emit_null_optional_fields = false })});
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
        if (self.choices.len != 1) {
            return null;
        }

        return self.choices[0];
    }
};

pub const Choice = struct {
    index: u32,
    message: Message,
    logprobs: ?struct {} = .{},
    finish_reason: FinishReason,

    pub fn text(self: Choice) ?[]const u8 {
        if (self.finish_reason == .stop) {
            switch (self.message.content orelse return null) {
                .text => |t| return t,
                .contents => |cs| for (cs) |c| if (c.type == .text) return c.text,
            }
        }

        return null;
    }

    pub fn toolCalls(self: Choice) ?[]const ToolCall {
        if (self.finish_reason == .tool_calls) {
            return self.message.tool_calls;
        }

        return null;
    }
};
