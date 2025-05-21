const std = @import("std");
const meta = @import("meta.zig");
const schema = @import("schema.zig");
const HttpClient = @import("client.zig").HttpClient;
const Options = @import("client.zig").Options;
const Response = @import("client.zig").Response;
const log = std.log.scoped(.ai);

pub const Config = struct {
    base_url: []const u8 = "https://api.openai.com/v1/",
    api_key: ?[]const u8 = null,
    timeout: ?usize = 2 * 60,
};

pub const CompletionReq = struct {
    model: []const u8,
    messages: []const Message,
    tools: []const Tool = &.{},
    response_format: ?struct {
        type: []const u8,
    } = null,
    max_tokens: u32 = 256,
    temperature: f32 = 1,
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

pub const CompletionRes = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []const struct {
        index: u32,
        message: Message,
        logprobs: ?struct {} = .{},
        finish_reason: FinishReason,
    },
    usage: struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    },
    system_fingerprint: ?[]const u8,

    pub fn text(self: CompletionRes) ?[]const u8 {
        for (self.choices) |choice| {
            if (choice.finish_reason == .stop) {
                return choice.message.content;
            }
        }

        return null;
    }

    pub fn toolCalls(self: CompletionRes) ?[]const ToolCall {
        for (self.choices) |choice| {
            if (choice.finish_reason == .tool_calls) {
                return choice.message.tool_calls.?;
            }
        }

        return null;
    }

    pub fn json(self: CompletionRes, arena: std.mem.Allocator, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(
            T,
            arena,
            try self.text(),
            .{ .ignore_unknown_fields = true },
        );
    }
};

pub const JsonReq = struct {
    model: []const u8,
    system_prompt: ?[]const u8 = null,
    prompt: []const u8,
    max_tokens: u32 = 512,
    temperature: f32 = 1,
};

pub const EmbeddingsReq = struct {
    model: []const u8,
    input: []const u8,
};

pub const EmbeddingsRes = struct {
    object: []const u8,
    model: []const u8,
    data: []const Embedding,
    usage: struct {
        prompt_tokens: u32,
        total_tokens: u32,
    },
};

pub const Embedding = struct {
    index: u32,
    object: []const u8,
    embedding: []const f32,
};

pub const Client = struct {
    client: *HttpClient,
    config: Config,

    pub fn createCompletion(self: *Client, arena: std.mem.Allocator, params: CompletionReq) !CompletionRes {
        const res = try self.request(arena, .{
            .method = .POST,
            .url = "chat/completions",
            .body = .json(&params),
        });

        return res.json(CompletionRes);
    }

    pub fn createJson(self: *Client, comptime T: type, arena: std.mem.Allocator, params: JsonReq) !T {
        const messages: [2]Message = .{
            .{ .role = "system", .content = params.system_prompt orelse undefined },
            .{ .role = "user", .content = params.prompt },
        };

        const res = try self.createCompletion(arena, .{
            .model = params.model,
            .messages = messages[@intFromBool(params.system_prompt == null)..], // Skip the system prompt if it's empty
            .response_format = .{ .type = "json_object" },
            .max_tokens = params.max_tokens,
            .temperature = params.temperature,
        });

        return res.json(T) catch |e| {
            if (e == error.AllocError) {
                return e;
            }

            log.debug("Failed to parse {s} from completion: {s}", .{ @typeName(T), res.choices[0].message.content });
            return error.InvalidCompletion;
        };
    }

    pub fn createEmbeddings(self: *Client, arena: std.mem.Allocator, params: EmbeddingsReq) !EmbeddingsRes {
        const res = try self.request(arena, .{
            .method = .POST,
            .url = "embeddings",
            .body = .json(&params),
        });

        return res.json(EmbeddingsRes);
    }

    fn request(self: *Client, arena: std.mem.Allocator, options: Options) !Response {
        var opts = options;
        opts.base_url = opts.base_url orelse self.config.base_url;
        opts.timeout = opts.timeout orelse self.config.timeout;

        if (self.config.api_key) |key| {
            opts.headers = &.{
                .{
                    .name = "Authorization",
                    .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{key}),
                },
            };
        }

        return self.client.request(arena, opts);
    }
};

pub const AgentOptions = struct {
    model: []const u8,
    max_tokens: u32 = 4096,
    temperature: f32 = 1,
    debug: bool = false,
};

pub const Agent = struct {
    arena: std.mem.Allocator,
    client: *Client,
    options: AgentOptions,
    // injector: *Injector,
    messages: std.ArrayListUnmanaged(Message),
    tools: std.ArrayListUnmanaged(Tool),
    result: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, client: *Client, options: AgentOptions) !Agent {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        return .{
            .arena = arena.allocator(),
            .client = client,
            .options = options,
            .messages = .empty,
            .tools = .empty,
            .result = null,
        };
    }

    pub fn deinit(self: *Agent) void {
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
        arena.deinit();
        arena.child_allocator.destroy(arena);
    }

    pub fn addMessage(self: *Agent, msg: Message) !void {
        if (self.options.debug) {
            log.debug("{s}: {?s}", .{ @tagName(msg.role), msg.content });

            if (msg.tool_calls) |tcs| {
                for (tcs) |tc| {
                    log.debug("  -> {s}({s})", .{ tc.function.name, tc.function.arguments });
                }
            }
        }

        try self.messages.append(self.arena, msg);
    }

    pub fn addTool(self: *Agent, tool: Tool) !void {
        try self.tools.append(self.arena, tool);
    }

    pub fn run(self: *Agent) ![]const u8 {
        while (try self.next()) |tcs| {
            for (tcs) |tc| {
                try self.accept(tc);
            }
        }

        return self.result orelse error.NoResult;
    }

    pub fn next(self: *Agent) !?[]const ToolCall {
        if (self.result != null) {
            return null;
        }

        const res = try self.client.createCompletion(self.arena, .{
            .model = self.options.model,
            .max_tokens = self.options.max_tokens,
            .temperature = self.options.temperature,

            .tools = self.tools.items,
            .messages = self.messages.items,
        });

        if (res.choices.len < 1) {
            return error.NoChoice;
        }

        try self.addMessage(res.choices[0].message);

        if (res.toolCalls()) |tcs| {
            for (tcs) |tc| {
                if (std.mem.eql(u8, tc.function.name, "final_result")) {
                    self.finish(tc.function.arguments);
                    return null;
                }
            }

            return tcs;
        }

        // TODO: if (maxlen) -> error
        // TODO: if (stop) -> finished (with text)

        self.finish(res.choices[0].message.content orelse "");

        return null;
    }

    pub fn accept(self: *Agent, tc: ToolCall) !void {
        try self.respond(tc, try self.exec(tc));
    }

    pub fn reject(self: *Agent, tc: ToolCall) !void {
        try self.respond(tc, error.ToolCallRejected);
    }

    pub fn respond(self: *Agent, tc: ToolCall, res: anytype) !void {
        const msg = Message.tool(tc.id, try self.stringify(res));
        try self.addMessage(msg);
    }

    pub fn retry(self: *Agent) void {
        while (self.messages.pop()) |msg| {
            if (msg.role == .assistant) return;
        }
    }

    pub fn exec(self: *Agent, tc: ToolCall) ![]const u8 {
        _ = self;
        _ = tc;
        @panic("TODO");
    }

    pub fn finish(self: *Agent, result: []const u8) void {
        self.result = result;
    }

    pub fn stringify(self: *Agent, res: anytype) ![]const u8 {
        // TODO: custom hook
        // TODO: slices as markdown table or at least CSV?
        const T = @TypeOf(res);

        if (comptime meta.isString(T)) {
            return res;
        }

        return switch (@typeInfo(T)) {
            .error_set => self.stringify(.{ .@"error" = res }),
            .error_union => if (res) |r| self.stringify(r) else |e| self.stringify(e),
            else => std.json.stringifyAlloc(self.arena, res, .{}),
        };
    }
};
