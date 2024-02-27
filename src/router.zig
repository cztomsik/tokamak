const std = @import("std");
const Injector = @import("injector.zig").Injector;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub fn router(comptime routes: type) fn (Injector, *Request, *Response) anyerror!void {
    const H = struct {
        fn handler(injector: Injector, req: *Request, res: *Response) anyerror!void {
            inline for (@typeInfo(routes).Struct.decls) |d| {
                if (comptime @typeInfo(@TypeOf(@field(routes, d.name))) != .Fn) continue;

                const method = comptime d.name[0 .. std.mem.indexOfScalar(u8, d.name, ' ') orelse @compileError("route must contain a space")];
                const pattern = d.name[method.len + 1 ..];
                const has_body: u1 = comptime if (std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "PUT")) 1 else 0;
                const param_count = comptime std.mem.count(u8, pattern, ":") + has_body;

                if (req.method == @field(std.http.Method, method)) {
                    if (req.match(pattern)) |params| {
                        const route_handler = comptime @field(routes, d.name);

                        var args: std.meta.ArgsTuple(@TypeOf(route_handler)) = undefined;
                        const mid = args.len - param_count;

                        inline for (0..mid) |i| {
                            args[i] = try injector.get(@TypeOf(args[i]));
                        }

                        inline for (mid..args.len) |i| {
                            const V = @TypeOf(args[i]);
                            args[i] = try if (comptime @typeInfo(V) == .Struct) req.readJson(V) else params.get(i - mid, V);
                        }

                        return res.send(@call(.auto, route_handler, args));
                    }
                }
            }

            return error.NotFound;
        }
    };
    return H.handler;
}
