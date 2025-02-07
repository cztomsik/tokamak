const std = @import("std");
const HttpClient = @import("client.zig").HttpClient;
const Options = @import("client.zig").Options;
const Response = @import("client.zig").Response;
const log = std.log.scoped(.openai);

pub const Config = struct {
    base_url: []const u8 = "https://api.openai.com/v1/",
    api_key: ?[]const u8 = null,
    timeout: ?usize = 2 * 60,
};

pub const CompletionReq = struct {
    model: []const u8,
    messages: []const Message,
    response_format: ?struct {
        type: []const u8,
    } = null,
    max_tokens: u32 = 256,
    temperature: f32 = 1,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,

    pub fn system(content: []const u8) Message {
        return .{ .role = "system", .content = content };
    }

    pub fn user(content: []const u8) Message {
        return .{ .role = "user", .content = content };
    }

    pub fn assistant(content: []const u8) Message {
        return .{ .role = "assistant", .content = content };
    }
};

pub const CompletionRes = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []const struct {
        index: u32,
        message: Message,
        logprobs: ?struct {},
        finish_reason: []const u8,
    },
    usage: struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    },
    system_fingerprint: ?[]const u8,
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

        return std.json.parseFromSliceLeaky(
            T,
            arena,
            res.choices[0].message.content,
            .{ .ignore_unknown_fields = true },
        ) catch |e| {
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
