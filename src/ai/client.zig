const std = @import("std");
const http = @import("../http.zig");
const chat = @import("chat.zig");
const embedding = @import("embedding.zig");
const log = std.log.scoped(.ai_client);

pub const Config = struct {
    base_url: []const u8 = "https://api.openai.com/v1/",
    api_key: ?[]const u8 = null,
    timeout: ?usize = 2 * 60,
};

pub const Client = struct {
    http_client: *http.Client,
    config: Config,

    pub fn createChatCompletion(self: *Client, arena: std.mem.Allocator, params: chat.Request) !chat.Response {
        const res = try self.request(arena, .{
            .method = .POST,
            .url = "chat/completions",
            .body = .json(&params),
        });

        return res.json(chat.Response);
    }

    pub fn createEmbeddings(self: *Client, arena: std.mem.Allocator, params: embedding.Request) !embedding.Response {
        const res = try self.request(arena, .{
            .method = .POST,
            .url = "embeddings",
            .body = .json(&params),
        });

        return res.json(embedding.Response);
    }

    fn request(self: *Client, arena: std.mem.Allocator, options: http.RequestOptions) !http.ClientResponse {
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

        return self.http_client.request(arena, opts);
    }
};
