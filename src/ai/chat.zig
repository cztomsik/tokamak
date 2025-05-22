const std = @import("std");
const schema = @import("../schema.zig");

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
    content: ?[]const u8,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub fn system(content: []const u8) Message {
        return .{
            .role = .system,
            .content = content,
        };
    }

    pub fn user(content: []const u8) Message {
        return .{
            .role = .user,
            .content = content,
        };
    }

    pub fn assistant(content: []const u8) Message {
        return .{
            .role = .assistant,
            .content = content,
        };
    }

    pub fn tool(call_id: []const u8, content: []const u8) Message {
        return .{
            .role = .tool,
            .content = content,
            .tool_call_id = call_id,
        };
    }

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
            return self.message.content;
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
