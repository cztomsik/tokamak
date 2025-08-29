// This is NOT supposed to be yet another-cli-framework. It should stay simple
// and easy to use, without any need for excessive configuration.
//
// If you are writing a CLI app, this might be a good start but it's unlikely
// that it will suit your needs later in the project. You've been warned.
//
// The primary use-case for this is to make it easy to provide a companion CLI
// binary to your EXISTING (likely server-side) application.
//
// THE IDEA is that you should be able to re-use your app DI module(s), with
// all the services, configuration, db. connections, etc. so when you run the
// CLI, you can easily invoke any `T.fun` you make available as command.
//
// You can use this for running db migrations, imports/exports, backups,
// or whatever.

const std = @import("std");
const meta = @import("meta.zig");
const yaml = @import("yaml.zig");
const Injector = @import("injector.zig").Injector;
const parseValue = @import("parse.zig").parseValue;

pub const OutputFormat = enum { auto, yaml, json };

pub const Context = struct {
    arena: std.mem.Allocator,
    bin: []const u8,
    command: *const Command,
    args: []const []const u8,
    in: *std.io.Reader,
    out: *std.io.Writer,
    err: *std.io.Writer,
    injector: *Injector,
    format: OutputFormat = .auto,

    /// Parse a string value into the requested type.
    pub fn parse(self: *Context, comptime T: type, s: []const u8) !T {
        return parseValue(T, s, self.arena);
    }

    pub fn output(self: *Context, res: anytype) !void {
        const T = @TypeOf(res);

        switch (@typeInfo(T)) {
            // std.json can't stringify void
            .void => return,
            // so that --json <cmd1> would still output { "error": MissingArg }
            // and we get error: MissingArg for free from yaml
            .error_set => return self.output(.{ .@"error" = res }),
            // none of the formats can stringify error unions
            .error_union => {
                if (res) |r| {
                    return self.output(r);
                } else |e| {
                    return self.output(e);
                }
            },
            else => {},
        }

        fmt: switch (self.format) {
            .auto => {
                if (meta.isString(T)) {
                    // workaround for https://github.com/ziglang/zig/issues/24323
                    var x = true;
                    _ = &x;
                    if (x) return self.out.print("{s}\n", .{res});
                }

                continue :fmt .yaml;
            },
            .json => {
                try self.out.print("{f}\n", .{
                    std.json.fmt(res, .{ .whitespace = .indent_2 }),
                });
            },
            .yaml => {
                var writer = yaml.Writer.init(self.out);
                try writer.writeValue(res);
                try self.out.writeByte('\n');
            },
        }
    }
};

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn (*Context) anyerror!void,
    tids: []const meta.TypeId,

    pub const usage: Command = cmd0("usage", "Show this help message", printUsage);

    pub fn cmd(comptime name: []const u8, comptime description: []const u8, comptime fun: anytype, comptime n_args: usize) Command {
        const info = @typeInfo(@TypeOf(fun));
        if (info != .@"fn") @compileError("Command handler must be a function");

        const params = info.@"fn".params;
        const n_deps = params.len - n_args;
        const n_req = blk: {
            var n: usize = n_args;
            while (n > 0 and meta.isOptional(params[n_deps + n - 1].type.?)) n -= 1;
            break :blk n;
        };

        const H = struct {
            fn handler(ctx: *Context) anyerror!void {
                var args: std.meta.ArgsTuple(@TypeOf(fun)) = undefined;

                if (ctx.args.len < n_req) {
                    return error.MissingArg;
                }

                inline for (0..n_deps) |i| {
                    args[i] = try ctx.injector.get(@TypeOf(args[i]));
                }

                inline for (0..n_req, n_deps..) |j, i| {
                    args[i] = try ctx.parse(@TypeOf(args[i]), ctx.args[j]);
                }

                inline for (n_req..n_args, n_deps + n_req..) |j, i| {
                    args[i] = if (j < ctx.args.len) try ctx.parse(@TypeOf(args[i]), ctx.args[j]) else null;
                }

                ctx.output(@call(.auto, fun, args)) catch {};
                return;
            }
        };

        return .{
            .name = name,
            .description = description,
            .handler = &H.handler,
            .tids = meta.tids(meta.fnParams(fun)[n_deps..]),
        };
    }

    pub fn cmd0(comptime name: []const u8, comptime description: []const u8, comptime fun: anytype) Command {
        return cmd(name, description, fun, 0);
    }

    pub fn cmd1(comptime name: []const u8, comptime description: []const u8, comptime fun: anytype) Command {
        return cmd(name, description, fun, 1);
    }

    pub fn cmd2(comptime name: []const u8, comptime description: []const u8, comptime fun: anytype) Command {
        return cmd(name, description, fun, 2);
    }

    pub fn cmd3(comptime name: []const u8, comptime description: []const u8, comptime fun: anytype) Command {
        return cmd(name, description, fun, 3);
    }
};

pub fn printUsage(ctx: *Context, cmds: []const Command) !void {
    try ctx.out.print("Usage: {s} [--json|--yaml] <command> [args...]\n\n", .{ctx.bin});

    try ctx.out.writeAll("Options:\n");
    try ctx.out.writeAll("  --json               Output in JSON format\n");
    try ctx.out.writeAll("  --yaml               Output in YAML format\n\n");

    try ctx.out.writeAll("Commands:\n");
    for (cmds) |cmd| {
        try ctx.out.print("  {s:<20} {s}\n", .{ cmd.name, cmd.description });
    }

    try ctx.out.writeAll("\nSyntax:\n");
    for (cmds) |cmd| {
        try ctx.out.print("  {s} {s}", .{ ctx.bin, cmd.name });
        for (cmd.tids) |tid| {
            try ctx.out.print(" <{s}>", .{tid.sname()});
        }
        try ctx.out.writeAll("\n");
    }
}

pub fn run(inj: *Injector, allocator: std.mem.Allocator, cmds: []const Command) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var in = std.fs.File.stdin().reader(&.{});
    var out = std.fs.File.stdout().writer(&.{});
    var err = std.fs.File.stderr().writer(&.{});

    // NOTE: We are using arena so we don't need to call argsFree()
    const args = try std.process.argsAlloc(arena.allocator());
    for (args) |arg| if (!std.unicode.utf8ValidateSlice(arg)) return error.InvalidArg;

    var format: OutputFormat = .auto;
    var cmd_args = args[1..];

    if (cmd_args.len > 0) {
        if (std.mem.eql(u8, cmd_args[0], "--json")) {
            format = .json;
            cmd_args = cmd_args[1..];
        } else if (std.mem.eql(u8, cmd_args[0], "--yaml")) {
            format = .yaml;
            cmd_args = cmd_args[1..];
        }
    }

    // TODO: --version
    // TODO: --help
    var cmd = Command.usage;
    if (cmd_args.len > 0) cmd = findCmd(cmds, cmd_args[0]) orelse cmd;

    var cx: Context = undefined;

    var child_inj: Injector = .init(&.{
        .ref(&cx),
        .ref(&cx.arena),
    }, inj);

    cx = .{
        .arena = arena.allocator(),
        .bin = std.fs.path.basename(args[0]),
        .command = &cmd,
        .args = cmd_args[@min(cmd_args.len, 1)..],
        .in = &in.interface,
        .out = &out.interface,
        .err = &err.interface,
        .injector = &child_inj,
        .format = format,
    };

    cmd.handler(&cx) catch |e| {
        cx.output(e) catch {};
        cx.out.writeAll("\n") catch {};
        printUsage(&cx, cmds) catch {};
    };
}

fn findCmd(cmds: []const Command, name: []const u8) ?Command {
    for (cmds) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    } else return null;
}
