const std = @import("std");
const http = @import("http.zig");
const testing = @import("testing.zig");

pub const Config = struct {
    base_url: []const u8 = "https://api.github.com/",
    api_key: ?[]const u8 = null,
    timeout: ?usize = 2 * 60,
};

// https://docs.github.com/en/rest/issues/issues?apiVersion=2022-11-28#list-repository-issues
// https://api.github.com/repos/cztomsik/tokamak/issues
pub const Issue = struct {
    url: []const u8,
    id: u64,
    number: u64,
    title: []const u8,
    state: []const u8,
    body: ?[]const u8,
};

// https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28#list-organization-repositories
// https://api.github.com/users/cztomsik/repos
pub const Repository = struct {
    id: u64,
    name: []const u8,
    description: ?[]const u8,
    url: []const u8,
};

pub const Client = struct {
    http_client: *http.Client,
    config: Config = .{},

    pub fn listRepoIssues(self: *Client, arena: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]const Issue {
        const res = try self.request(arena, .{
            .method = .GET,
            .url = try std.fmt.allocPrint(arena, "repos/{s}/{s}/issues", .{ owner, repo }),
        });

        return res.json([]const Issue);
    }

    pub fn listRepos(self: *Client, arena: std.mem.Allocator, owner: []const u8) ![]const Repository {
        const res = try self.request(arena, .{
            .method = .GET,
            .url = try std.fmt.allocPrint(arena, "users/{s}/repos", .{owner}),
        });

        return res.json([]const Repository);
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

test "listRepoIssues" {
    const mock, const http_client = try testing.httpClient();
    defer mock.deinit();

    var github_client = Client{ .http_client = http_client };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try mock.expectNext("200 GET repos/cztomsik/tokamak/issues",
        \\[
        \\  {
        \\    "url": "https://api.github.com/repos/cztomsik/tokamak/issues/1",
        \\    "id": 123,
        \\    "number": 1,
        \\    "title": "First issue",
        \\    "state": "open",
        \\    "body": "Issue body"
        \\  },
        \\  {
        \\    "url": "https://api.github.com/repos/cztomsik/tokamak/issues/2",
        \\    "id": 456,
        \\    "number": 2,
        \\    "title": "Second issue",
        \\    "state": "closed",
        \\    "body": null
        \\  }
        \\]
    );

    const issues = try github_client.listRepoIssues(arena.allocator(), "cztomsik", "tokamak");

    try testing.expectTable(issues,
        \\| id  | number | title        | state  |
        \\|-----|--------|--------------|--------|
        \\| 123 | 1      | First issue  | open   |
        \\| 456 | 2      | Second issue | closed |
    );
}

test "listRepos" {
    const mock, const http_client = try testing.httpClient();
    defer mock.deinit();

    var github_client = Client{ .http_client = http_client };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try mock.expectNext("200 GET users/cztomsik/repos",
        \\[
        \\  {
        \\    "id": 123,
        \\    "name": "tokamak",
        \\    "description": "Web framework for Zig",
        \\    "url": "https://api.github.com/repos/cztomsik/tokamak"
        \\  },
        \\  {
        \\    "id": 456,
        \\    "name": "napigen",
        \\    "description": null,
        \\    "url": "https://api.github.com/repos/cztomsik/napigen"
        \\  }
        \\]
    );

    const repos = try github_client.listRepos(arena.allocator(), "cztomsik");

    try testing.expectTable(repos,
        \\| id  | name    |
        \\|-----|---------|
        \\| 123 | tokamak |
        \\| 456 | napigen |
    );
}

test "auth" {
    const mock, const http_client = try testing.httpClient();
    defer mock.deinit();

    var github_client = Client{ .http_client = http_client, .config = .{ .api_key = "test-token" } };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try mock.expectNext("200 GET users/cztomsik/repos Authorization: Bearer test-token", "[]");

    _ = try github_client.listRepos(arena.allocator(), "cztomsik");
}
