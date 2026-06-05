const std = @import("std");
const log = std.log.scoped(.monitor);
const meta = @import("meta.zig");

/// Runs the given processes in parallel, restarting them if they exit.
///
/// The processes are tuples of the form:
///    .{ "name", &fn, .{ ...args } }
///
/// Example:
///    pub fn main() !void {
///        // do some init checks and setup if needed
///
///        return monitor(.{
///            .{ "server", &serverFn, .{ 8080 } },
///            .{ "worker 1", &workerFn, .{ 1 } },
///            .{ "worker 2", &workerFn, .{ 2 } },
///        });
///    }
pub fn monitor(processes: anytype) noreturn {
    if (comptime !isTupleOfProcesses(@TypeOf(processes))) {
        @compileError("Expected tuple of .{ \"name\", &fn, .{ ...args } }");
    }

    var pids = std.mem.zeroes([processes.len]std.posix.pid_t);

    while (true) {
        inline for (0..processes.len) |i| {
            if (pids[i] == 0) {
                const child = std.c.fork();
                if (child == -1) @panic("fork failed");
                if (child == 0) return run(processes[i]);

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

fn run(proc: anytype) noreturn {
    // Helps with mixing logs from different processes.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    setproctitle(proc[0]);

    const res = @call(.auto, proc[1], proc[2]);

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

fn setproctitle(name: [:0]const u8) void {
    _ = name; // autofix
    // TODO: zig17 removed argv so we might need to access is via init.minimal.args.vector or something like that???

    // // name includes path so we should always have some extra space
    // const dest = std.mem.span(std.os.argv[0]);
    // if (std.os.argv.len == 1 and dest.len >= name.len) {
    //     @memcpy(dest[0..name.len], name);
    //     dest.ptr[name.len] = 0;
    // } else log.debug("Could not rewrite process name {s}\ndest: {s}", .{ name, std.os.argv[0] });
}

fn isTupleOfProcesses(comptime T: type) bool {
    if (!meta.isTuple(T)) return false;

    inline for (@typeInfo(T).@"struct".field_types) |ft| {
        if (!meta.isTuple(ft)) return false;
        if (@typeInfo(ft).@"struct".field_types.len != 3) return false;
    }

    return true;
}
