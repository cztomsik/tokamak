const std = @import("std");
const HttpClient = @import("client.zig").HttpClient;
const Options = @import("client.zig").Options;
const Response = @import("client.zig").Response;

pub const Config = struct {
    base_url: []const u8 = "https://api.openai.com/v1/",
    api_key: ?[]const u8 = null,
};

pub const CompletionReq = struct {
    model: []const u8,
    messages: []const Message,
    // response_format: ?struct { type: []const u8 } = null,
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
        const res = try self.request(arena, .POST, "chat/completions", .{ .body = .json(&params) });
        return res.json(CompletionRes);
    }

    pub fn createEmbeddings(self: *Client, arena: std.mem.Allocator, params: EmbeddingsReq) !EmbeddingsRes {
        const res = try self.request(arena, .POST, "embeddings", .{ .body = .json(&params) });
        return res.json(EmbeddingsRes);
    }

    fn request(self: *Client, arena: std.mem.Allocator, method: std.http.Method, url: []const u8, options: Options) !Response {
        var opts = options;

        opts.base_url = self.config.base_url;
        opts.method = method;
        opts.url = url;

        if (self.config.api_key) |key| {
            opts.headers = &.{.{
                .name = "Authorization",
                .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{key}),
            }};
        }

        return self.client.request(arena, opts);
    }
};
