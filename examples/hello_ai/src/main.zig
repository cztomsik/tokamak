// llama-server -hf Qwen/Qwen3-8B-GGUF:Q8_0 --jinja --reasoning-format deepseek -ngl 99 -fa --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0

const std = @import("std");
const tk = @import("tokamak");

const Config = struct {
    sendmail: tk.sendmail.Config = .{},
    http_client: tk.http.ClientConfig = .{},
    ai_client: tk.ai.ClientConfig = .{
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

const MailMessage = struct {
    from: []const u8,
    title: []const u8,
    date: []const u8,
    status: enum { read, unread },

    fn init(from: []const u8, title: []const u8, date: []const u8, read: bool) MailMessage {
        return .{ .from = from, .title = title, .date = date, .status = if (read) .read else .unread };
    }
};

const MailService = struct {
    const items: []const MailMessage = &.{
        .init("Sarah Chen", "Project Alpha Kick-off Meeting Notes", "2025-05-25", false),
        .init("Marketing Team", "Your Monthly Newsletter - May 2025", "2025-05-25", true),
        .init("DevOps Alerts", "High CPU Usage on Server 1", "2025-05-25", false),
        .init("Finance Department", "Important: Upcoming Payroll Changes", "2025-05-25", false),
        .init("Jessica", "Love you", "2025-05-24", true),
        .init("John Wick", "We need to talk.", "2025-05-24", false),
    };

    pub fn listMessages(_: *MailService, params: struct { limit: u32 = 10 }) []const MailMessage {
        return items[0..@min(params.limit, items.len)];
    }
};

const App = struct {
    math: MathService,
    mail: MailService,
    sendmail: tk.sendmail.Sendmail,
    http_client: tk.http.Client,
    ai_client: tk.ai.Client,
    agent_toolbox: tk.ai.AgentToolbox,
    agent_runtime: tk.ai.AgentRuntime,

    pub fn afterBundleInit(tbox: *tk.ai.AgentToolbox) !void {
        try tbox.addTool("add", "Add two numbers", MathService.add);
        try tbox.addTool("mul", "Multiply two numbers", MathService.mul);
        try tbox.addTool("checkMailbox", "List email messages (limit = 10)", MailService.listMessages);
        try tbox.addTool("sendMail", "Send email (from can be null)", tk.sendmail.Sendmail.sendMail);
    }

    pub fn hello_ai(gpa: std.mem.Allocator, agr: *tk.ai.AgentRuntime) !void {
        try runAgent(gpa, agr, "Can you tell how much is 12 * (32 + 4) and send the answer to foo@bar.com?", &.{ "add", "mul", "sendMail" });
        try runAgent(gpa, agr, "Is there anything important in my mailbox? Show me table, sorted on priority", &.{"checkMailbox"});
    }

    fn runAgent(gpa: std.mem.Allocator, agr: *tk.ai.AgentRuntime, prompt: []const u8, tools: []const []const u8) !void {
        var agent = try agr.createAgent(gpa, .{ .model = "", .tools = tools });
        defer agent.deinit();

        try agent.addMessage(.system("You are a helpful assistant./no_think"));
        try agent.addMessage(.user(prompt));

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
