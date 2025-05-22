// llama-server -hf Qwen/Qwen3-8B-GGUF:Q8_0 --jinja --reasoning-format deepseek -ngl 99 -fa --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0

const std = @import("std");
const tk = @import("tokamak");

const Config = struct {
    client: tk.client.Config = .{},
    ai: tk.ai.ClientConfig = .{
        .base_url = "http://localhost:8080/v1/",
    },
};

const MathService = struct {
    n_used: i32 = 0,

    // TODO: auto-translate from tuple to object (at least for openai)
    pub fn add(self: *MathService, params: struct { a: i32, b: i32 }) i32 {
        defer self.n_used += 1;
        return params.a + params.b;
    }

    pub fn mul(self: *MathService, params: struct { a: i32, b: i32 }) i32 {
        defer self.n_used += 1;
        return params.a * params.b;
    }
};

const App = struct {
    math: MathService,
    client: tk.client.HttpClient,
    ai_client: tk.ai.Client,
    agent_toolbox: tk.ai.AgentToolbox,
    agent_runtime: tk.ai.AgentRuntime,

    pub fn afterBundleInit(tbox: *tk.ai.AgentToolbox) !void {
        try tbox.addTool("add", "Add two numbers", MathService.add);
        try tbox.addTool("mul", "Multiply two numbers", MathService.mul);
    }

    pub fn hello_ai(gpa: std.mem.Allocator, agr: *tk.ai.AgentRuntime) !void {
        var agent = try agr.createAgent(gpa, .{ .model = "" });
        defer agent.deinit();

        try agent.addMessage(.system("You are a helpful assistant."));
        try agent.addMessage(.user("Can you tell how much is 2 * (3 + 4)?"));

        const res = try agent.run();
        std.debug.print("{s}\n", .{res});
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
