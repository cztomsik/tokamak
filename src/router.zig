const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Responder = @import("responder.zig").Responder;

pub fn router(comptime routes: type) fn (Injector, std.Uri, *std.http.Server.Response, *Responder) anyerror!void {
    const H = struct {
        fn handler(injector: Injector, uri: std.Uri, res: *std.http.Server.Response, responder: *Responder) anyerror!void {
            inline for (@typeInfo(routes).Struct.decls) |d| {
                const method = comptime d.name[0 .. std.mem.indexOfScalar(u8, d.name, ' ') orelse unreachable];
                const pattern = d.name[method.len + 1 ..];
                const param_count = comptime std.mem.count(u8, pattern, ":");

                if (res.request.method == @field(std.http.Method, method)) {
                    if (Params.match(pattern, uri.path)) |params| {
                        const route_handler = comptime @field(routes, d.name);

                        var args: std.meta.ArgsTuple(@TypeOf(route_handler)) = undefined;
                        inline for (0..args.len - param_count) |i| {
                            args[i] = try injector.get(@TypeOf(args[i]));
                        }
                        inline for (args.len - param_count..args.len) |i| {
                            const V = @TypeOf(args[i]);
                            args[i] = try if (comptime @typeInfo(V) == .Struct) readJson(res, V) else params.get(i - 1, V);
                        }

                        return responder.send(@call(.auto, route_handler, args));
                    }
                }
            }

            return error.NotFound;
        }
    };
    return H.handler;
}

/// Reads the request body as JSON.
pub fn readJson(res: *std.http.Server.Response, comptime T: type) !T {
    var reader = std.json.reader(res.allocator, res.reader());

    return std.json.parseFromTokenSourceLeaky(
        T,
        res.allocator,
        &reader,
        .{ .ignore_unknown_fields = true },
    );
}

pub const Params = struct {
    matches: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn match(pattern: []const u8, path: []const u8) ?Params {
        var res = Params{};
        var pattern_parts = std.mem.tokenizeScalar(u8, pattern, '/');
        var path_parts = std.mem.tokenizeScalar(u8, path, '/');

        while (true) {
            const pat = pattern_parts.next() orelse return if (pattern[pattern.len - 1] == '*' or path_parts.next() == null) res else null;
            const pth = path_parts.next() orelse return null;
            const dynamic = pat[0] == ':' or pat[0] == '*';

            if (std.mem.indexOfScalar(u8, pat, '.')) |i| {
                const j = (if (dynamic) std.mem.lastIndexOfScalar(u8, pth, '.') else std.mem.indexOfScalar(u8, pth, '.')) orelse return null;

                if (match(pat[i + 1 ..], pth[j + 1 ..])) |ch| {
                    for (ch.matches, res.len..) |s, l| res.matches[l] = s;
                    res.len += ch.len;
                } else return null;
            }

            if (!dynamic and !std.mem.eql(u8, pat, pth)) return null;

            if (pat[0] == ':') {
                res.matches[res.len] = pth;
                res.len += 1;
            }
        }
    }

    pub fn get(self: *const Params, index: usize, comptime T: type) !T {
        const s = if (index < self.len) self.matches[index] else return error.NoMatch;

        return switch (@typeInfo(T)) {
            .Int => std.fmt.parseInt(T, s, 10),
            else => s,
        };
    }
};
