const std = @import("std");
const log = std.log.scoped(.monitor);
const meta = @import("meta.zig");
const tkApp = @import("app.zig");

/// Runs the given processes in parallel, restarting them if they exit.
///
/// Each process is a tuple of the form:
///    .{ "name", mods, &fn }
///
/// The function `fn` will be called via `tk.app.run(init, fn, mods)` for
/// dependency injection.
///
/// Example:
///    pub fn main(init: std.process.Init) !void {
///        const mods: []const type = &.{App};
///        tk.monitor(init, .{
///            .{ "server", mods, server.run },
///            .{ "worker", mods, worker.run },
///        });
///    }
pub fn monitor(init: std.process.Init, processes: anytype) noreturn {
    if (comptime !isTupleOfProcesses(@TypeOf(processes))) {
        @compileError("Expected tuple of .{ \"name\", mods, &fn }");
    }

    var pids = std.mem.zeroes([processes.len]std.posix.pid_t);

    while (true) {
        inline for (0..processes.len) |i| {
            if (pids[i] == 0) {
                const child = std.c.fork();
                if (child == -1) @panic("fork failed");
                if (child == 0) return run(init, processes[i]);

                log.debug("start: #{d} {s} pid: {d}", .{ i, processes[i][0], child });
                pids[i] = child;
            }
        }

        const exited = std.c.waitpid(0, null, 0);
        inline for (0..processes.len) |i| {
            if (pids[i] == exited) {
                log.debug("exit: #{d} {s} pid: {d}", .{ i, processes[i][0], exited });
                pids[i] = 0;
            }
        }
    }
}

fn run(init: std.process.Init, proc: anytype) noreturn {
    // Helps with mixing logs from different processes.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    setproctitle(init, proc[0]);

    const res = tkApp.run(init, proc[2], proc[1]);

    if (comptime @typeInfo(@TypeOf(res)) == .error_union) {
        _ = res catch |e| {
            log.err("{s}", .{@errorName(e)});

            const stderr = std.debug.lockStderr(&.{}).terminal();
            defer std.debug.unlockStderr();

            if (@errorReturnTrace()) |et| {
                std.debug.writeErrorReturnTrace(et, stderr) catch {};
            }

            std.process.exit(1);
        };
    }

    std.process.exit(0);
}

fn setproctitle(init: std.process.Init, name: [:0]const u8) void {
    const argv = init.minimal.args.vector;
    if (argv.len == 0) return;

    // // name includes path so we should always have some extra space
    const dest = std.mem.sliceTo(@as([*:0]u8, @constCast(argv[0])), 0);

    if (argv.len == 1 and dest.len >= name.len) {
        @memcpy(dest[0..name.len], name);
        dest.ptr[name.len] = 0;
    } else log.debug("Could not rewrite process name {s}\ndest: {s}", .{ name, argv[0] });
}

fn isTupleOfProcesses(comptime T: type) bool {
    if (!meta.isTuple(T)) return false;

    inline for (@typeInfo(T).@"struct".field_types) |ft| {
        if (!meta.isTuple(ft)) return false;
        if (@typeInfo(ft).@"struct".field_types.len != 3) return false;
    }

    return true;
}
