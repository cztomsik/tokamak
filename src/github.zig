const std = @import("std");
const HttpClient = @import("client.zig").HttpClient;
const Options = @import("client.zig").Options;
const Response = @import("client.zig").Response;
const log = std.log.scoped(.github);

pub const Config = struct {
    base_url: []const u8 = "https://api.github.com/",
    api_key: ?[]const u8 = null,
    timeout: ?usize = 2 * 60,
};

// https://docs.github.com/en/rest/issues/issues?apiVersion=2022-11-28#list-repository-issues
// but in the order from curl response https://api.github.com/repos/cztomsik/tokamak/issues
pub const Issue = struct {
    url: []const u8,
    // repository_url: []const u8,
    // labels_url: []const u8,
    // comments_url: []const u8,
    // events_url: []const u8,
    // html_url: []const u8,
    id: u64,
    node_id: []const u8,
    number: u64,
    title: []const u8,
    // user: ?struct {}, // TODO
    labels: []const IssueLabel,
    state: []const u8,
    locked: bool,
    // assignee: ?struct {}, // TODO
    // assignees: []const struct {}, // TODO
    // milestone: ?struct {}, // TODO
    comments: u64,
    created_at: []const u8,
    updated_at: []const u8,
    closed_at: ?[]const u8,
    // author_association: []const u8, // TODO
    active_lock_reason: ?[]const u8,
    // sub_issues_summary: struct {}, // TODO
    body: ?[]const u8,
    // closed_by: ?struct {}, // TODO
    // reactions: struct {}, // TODO
    // timeline_url: []const u8,
    // performed_via_github_app: ?struct {}, // TODO
    // state_reason: ?[]const u8,
    // pull_request: ?struct {}, // TODO
    // draft: bool, // TODO
    // body_html: ?[]const u8, // TODO
    // body_text: ?[]const u8, // TODO
    // type: ?struct {}, // TODO
    // repository: struct {}, // TODO
};

const IssueLabel = struct {
    id: u64,
    node_id: []const u8,
    url: []const u8,
    name: []const u8,
    description: ?[]const u8,
    color: []const u8,
    default: bool,
};

pub const Client = struct {
    client: *HttpClient,
    config: Config,

    pub fn listRepoIssues(self: *Client, arena: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]const Issue {
        const res = try self.request(arena, .{
            .method = .GET,
            .url = try std.fmt.allocPrint(arena, "repos/{s}/{s}/issues", .{ owner, repo }),
        });

        return res.json([]const Issue);
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
