const std = @import("std");
const tk = @import("tokamak");

const App = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{
        .get("/", hello),
        .get("/err", @"error"),
    },

    pub fn errorHandler(ctx: *tk.Context, err: anyerror) !void {
        switch (err) {
            error.FakeError => try ctx.send(.{
                .message = "Fake error occurs",
            }),
            else => try ctx.send(.{
                .message = "Another error occurs",
            }),
        }
    }

    fn hello() ![]const u8 {
        return "Hello, world!";
    }
    fn @"error"() !void {
        return error.FakeError;
    }
};

pub fn main() !void {
    try tk.app.run(&.{App});
}
