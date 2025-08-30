const std = @import("std");
const meta = @import("../meta.zig");
const event = @import("../event.zig");
const chat = @import("chat.zig");
const Injector = @import("../injector.zig").Injector;
const Client = @import("client.zig").Client;
const stringifyAlloc = @import("fmt.zig").stringifyAlloc;
const log = std.log.scoped(.ai_agent);

pub const AgentOptions = struct {
    debug: bool = true,
    model: []const u8,
    tools: []const []const u8,
    max_tokens: u32 = 4096,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
};

pub const Agent = struct {
    arena: std.mem.Allocator,
    runtime: *AgentRuntime,
    options: AgentOptions,
    messages: std.ArrayListUnmanaged(chat.Message) = .empty,
    result: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, runtime: *AgentRuntime, options: AgentOptions) !Agent {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        return .{
            .arena = arena.allocator(),
            .runtime = runtime,
            .options = options,
        };
    }

    pub fn deinit(self: *Agent) void {
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
        arena.deinit();
        arena.child_allocator.destroy(arena);
    }

    pub fn addMessage(self: *Agent, msg: chat.Message) !void {
        if (self.options.debug) {
            // log.debug("{s}: {?s}", .{ @tagName(msg.role), msg.content });

            if (msg.tool_calls) |tcs| {
                for (tcs) |tc| {
                    log.debug("  -> {s}({s})", .{ tc.function.name, tc.function.arguments });
                }
            }
        }

        try self.messages.append(self.arena, msg);
    }

    pub fn run(self: *Agent) ![]const u8 {
        while (try self.next()) |tcs| {
            try self.acceptAll(tcs);
        }

        return self.result orelse error.NoResult;
    }

    pub fn next(self: *Agent) !?[]const chat.ToolCall {
        if (self.result != null) {
            return null;
        }

        const res = try self.runtime.createCompletion(self);

        const choice = res.singleChoice() orelse return error.NoChoice;
        try self.addMessage(choice.message);

        if (choice.toolCalls()) |tcs| {
            for (tcs) |tc| {
                if (std.mem.eql(u8, tc.function.name, "final_result")) {
                    self.finish(tc.function.arguments);
                    return null;
                }
            }

            return tcs;
        }

        if (choice.finish_reason == .length) {
            return error.MaxLen;
        }

        if (choice.text()) |text| {
            self.finish(text);
        }

        return null;
    }

    pub fn finish(self: *Agent, result: []const u8) void {
        self.result = result;
    }

    pub fn acceptAll(self: *Agent, tcs: []const chat.ToolCall) !void {
        for (tcs) |tc| {
            try self.accept(tc);
        }
    }

    pub fn accept(self: *Agent, tc: chat.ToolCall) !void {
        try self.respond(tc, try self.runtime.execTool(self, tc));
    }

    pub fn reject(self: *Agent, tc: chat.ToolCall) !void {
        try self.respond(tc, error.ToolCallRejected);
    }

    pub fn respond(self: *Agent, tc: chat.ToolCall, res: anytype) !void {
        const content = try stringifyAlloc(self.arena, res);

        try self.addMessage(.{
            .role = .tool,
            .content = .{ .text = content },
            .tool_call_id = tc.id,
        });
    }

    pub fn retry(self: *Agent) void {
        while (self.messages.pop()) |msg| {
            if (msg.role == .assistant) return;
        }
    }
};

pub const AgentRuntime = struct {
    event_bus: ?event.Bus = null,
    client: *Client,
    toolbox: *AgentToolbox,

    pub fn createAgent(self: *AgentRuntime, allocator: std.mem.Allocator, options: AgentOptions) !Agent {
        return Agent.init(allocator, self, options);
    }

    fn createCompletion(self: *AgentRuntime, agent: *Agent) !chat.Response {
        if (self.event_bus) |bus| {
            _ = .{ bus, agent };
            // TODO: try bus.dispatch(Xxx);
        }

        return self.client.createChatCompletion(agent.arena, .{
            .model = agent.options.model,
            .max_tokens = agent.options.max_tokens,
            .temperature = agent.options.temperature,
            .top_p = agent.options.top_p,

            .messages = agent.messages.items,
            .tools = try self.toolbox.query(agent.arena, agent.options.tools),
        });
    }

    fn execTool(self: *AgentRuntime, agent: *Agent, tool: chat.ToolCall) ![]const u8 {
        if (self.event_bus) |bus| {
            _ = .{ bus, agent };
            // TODO: try bus.dispatch(Xxx);
        }

        const res = self.toolbox.execTool(agent.arena, tool.function.name, tool.function.arguments);
        return try stringifyAlloc(agent.arena, res);
    }
};

pub const AgentTool = struct {
    tool: chat.Tool,
    handler: *const fn (inj: *Injector, arena: std.mem.Allocator, args: []const u8) anyerror![]const u8,

    // TODO: tool0(), tool1(), toolN() but we will need to work around openai schema limitations first
    fn init(comptime name: []const u8, comptime description: []const u8, comptime handler: anytype) AgentTool {
        const H = struct {
            fn handleTool(inj: *Injector, arena: std.mem.Allocator, args: []const u8) anyerror![]const u8 {
                const arg = try std.json.parseFromSliceLeaky(meta.LastArg(handler), arena, args, .{});

                const res = try inj.call(handler, .{arg});
                return stringifyAlloc(arena, res);
            }
        };

        return .{
            .tool = .{
                .function = .{
                    .name = name,
                    .description = description,
                    .parameters = .forType(meta.LastArg(handler)),
                },
            },
            .handler = H.handleTool,
        };
    }
};

pub const AgentToolbox = struct {
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    injector: *Injector,
    tools: std.StringHashMapUnmanaged(AgentTool) = .empty,

    pub fn init(allocator: std.mem.Allocator, injector: *Injector) AgentToolbox {
        return .{
            .allocator = allocator,
            .injector = injector,
        };
    }

    pub fn deinit(self: *AgentToolbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // TODO: free duped strings
        self.tools.deinit(self.allocator);
    }

    // TODO: remove comptime, but we need to dupe strings then (meta.dupe? meta.free?)
    pub fn addTool(self: *AgentToolbox, comptime name: []const u8, comptime description: []const u8, comptime handler: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tool = AgentTool.init(name, description, handler);
        try self.tools.putNoClobber(self.allocator, name, tool);
    }

    pub fn removeTool(self: *AgentToolbox, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.tools.remove(name);
    }

    fn query(self: *AgentToolbox, arena: std.mem.Allocator, names: []const []const u8) ![]const chat.Tool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf = std.array_list.Managed(chat.Tool).init(arena);

        for (names) |name| {
            const tool = self.tools.get(name) orelse continue;
            const copy = try meta.dupe(arena, tool.tool);
            try buf.append(copy);
        }

        return buf.toOwnedSlice();
    }

    fn execTool(self: *AgentToolbox, arena: std.mem.Allocator, name: []const u8, args: []const u8) ![]const u8 {
        // NOTE: we assume that tool handlers are always comptime
        //       so we can just copy the pointer and release the lock
        self.mutex.lock();

        if (self.tools.get(name)) |tool| {
            self.mutex.unlock();
            return tool.handler(self.injector, arena, args);
        }

        self.mutex.unlock();
        return error.NotFound;
    }
};

test AgentToolbox {
    var inj = Injector.empty;
    var tbox = AgentToolbox{ .allocator = std.testing.allocator, .injector = &inj };
    defer tbox.deinit();

    const H = struct {
        fn add(params: struct { a: u32, b: u32 }) u32 {
            return params.a + params.b;
        }
    };

    try tbox.addTool("add", "Add two numbers", H.add);
    defer _ = tbox.removeTool("add");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try tbox.execTool(arena.allocator(), "add", "{\"a\":1,\"b\":2}");
    try std.testing.expectEqualStrings("3", res);
}
