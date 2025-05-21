// llama-server -hf Qwen/Qwen3-8B-GGUF:Q8_0 --jinja --reasoning-format deepseek -ngl 99 -fa --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0

const std = @import("std");
const tk = @import("tokamak");

const Config = struct {
    client: tk.client.Config = .{},
    ai: tk.ai.Config = .{
        .base_url = "http://localhost:8080/v1/",
    },
};

const MathService = struct {
    n_used: i32 = 0,

    pub fn add(self: *MathService, a: i32, b: i32) i32 {
        defer self.n_used += 1;
        return a + b;
    }

    pub fn mul(self: *MathService, a: i32, b: i32) i32 {
        defer self.n_used += 1;
        return a * b;
    }
};

const App = struct {
    client: tk.client.HttpClient,
    ai: tk.ai.Client,
    math: MathService,

    pub fn hello_ai(gpa: std.mem.Allocator, ai: *tk.ai.Client, math: *MathService) !void {
        const tools: []const tk.ai.Tool = &.{
            .tool("add", "Add two numbers", struct { i32, i32 }),
            .tool("mul", "Multiply two numbers", struct { i32, i32 }),
        };

        var messages = std.ArrayList(tk.ai.Message).init(gpa);
        defer messages.deinit();

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        try messages.append(.system("You are a helpful assistant."));
        try messages.append(.user("Can you tell how much is 2 * (3 + 4)?"));

        for (messages.items) |msg| {
            std.debug.print("{s}: {s}\n", .{ @tagName(msg.role), msg.content.? });
        }

        var res = try ai.createCompletion(arena.allocator(), .{
            .model = "",
            .messages = messages.items,
            .tools = tools,
            .max_tokens = 16_384,
        });

        while (res.toolCalls()) |tcs| {
            try messages.append(res.choices[0].message);

            for (tcs) |tc| {
                std.debug.print("tool: {s}({s})\n", .{ tc.function.name, tc.function.arguments });

                if (std.mem.eql(u8, tc.function.name, "add")) {
                    const a, const b = try std.json.parseFromSliceLeaky(struct { i32, i32 }, arena.allocator(), tc.function.arguments, .{});
                    try messages.append(.tool(tc.id, try std.fmt.allocPrint(arena.allocator(), "{}", .{std.json.fmt(math.add(a, b), .{})})));
                }

                if (std.mem.eql(u8, tc.function.name, "mul")) {
                    const a, const b = try std.json.parseFromSliceLeaky(struct { i32, i32 }, arena.allocator(), tc.function.arguments, .{});
                    try messages.append(.tool(tc.id, try std.fmt.allocPrint(arena.allocator(), "{}", .{std.json.fmt(math.mul(a, b), .{})})));
                }

                res = try ai.createCompletion(arena.allocator(), .{
                    .model = "",
                    .messages = messages.items,
                    .tools = tools,
                    .max_tokens = 16_384,
                });
            }
        }

        std.debug.print("{s}\n", .{res.text().?});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const ct = try tk.Container.init(gpa.allocator(), &.{ Config, App });
    defer ct.deinit();

    try ct.injector.call(App.hello_ai, .{});
    try std.testing.expectEqual(2, ct.injector.find(*MathService).?.n_used);
}
