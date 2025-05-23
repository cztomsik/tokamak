const std = @import("std");
const tpl = @import("tpl.zig");

pub const Config = struct {
    path: []const u8 = "/usr/sbin/sendmail",
    args: []const []const u8 = &.{},
    default_from: ?[]const u8 = null,
};

pub const Message = struct {
    from: ?[]const u8 = null,
    to: []const u8,
    subject: []const u8,
    text: []const u8,
    // html: []const u8,
};

pub const Sendmail = struct {
    config: Config = .{},

    pub fn sendMail(self: *Sendmail, allocator: std.mem.Allocator, message: Message) !void {
        var msg = message;
        msg.from = msg.from orelse self.config.default_from;

        if (msg.from) |from| try checkAddress(from);
        try checkAddress(msg.to);

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(self.config.path);

        // Ignore dots alone on lines by themselves in incoming messages. Should be set for STDIN
        try args.append("-i");

        // Custom args
        for (self.config.args) |arg| {
            try args.append(arg);
        }

        // Add sender
        if (msg.from) |from| {
            try args.append("-f");
            try args.append(from);
        }

        // Add recipient (TODO: multi)
        try args.append(msg.to);

        // Create child process
        var child = std.process.Child.init(args.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        // Spawn
        child.spawn() catch |err| switch (err) {
            error.FileNotFound => return error.SendmailNotFound,
            else => return err,
        };

        // Write
        if (child.stdin) |stdin| {
            writeMessage(msg, stdin.writer().any()) catch |err| {
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                return err;
            };
            stdin.close();
            child.stdin = null; // Otherwise wait() would try to close it again
        } else return error.CouldNotWrite;

        // Wait
        const term = try child.wait();

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    return; // Success
                } else if (code == 127) {
                    return error.SendmailNotFound;
                } else {
                    return error.SendmailFailed;
                }
            },
            .Signal, .Stopped, .Unknown => {
                return error.ProcessError;
            },
        }
    }

    fn checkAddress(addr: []const u8) !void {
        // Reject empty, prevent arg injection
        if (addr.len == 0 or addr[0] == '-') {
            return error.InvalidAddress;
        }
    }

    fn writeMessage(msg: Message, writer: std.io.AnyWriter) !void {
        const template = tpl.Template.parseComptime(
            \\To: {{to}}
            \\{{#from}}From: {{from}}
            \\{{/from}}
            \\Subject: {{subject}}
            \\
            \\{{text}}
            \\
        );

        try template.render(msg, writer);
    }
};

test "fmt" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var msg: Message = .{ .to = "foo@bar.com", .subject = "Hello", .text = "Hello!" };

    try Sendmail.writeMessage(msg, buf.writer().any());
    try std.testing.expectEqualStrings(
        \\To: foo@bar.com
        \\Subject: Hello
        \\
        \\Hello!
        \\
    , buf.items);

    msg.from = "test@acme.org";
    buf.items.len = 0;

    try Sendmail.writeMessage(msg, buf.writer().any());
    try std.testing.expectEqualStrings(
        \\To: foo@bar.com
        \\From: test@acme.org
        \\Subject: Hello
        \\
        \\Hello!
        \\
    , buf.items);
}
