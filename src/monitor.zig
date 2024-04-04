const std = @import("std");
const log = std.log.scoped(.monitor);

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
                const child = std.posix.fork() catch @panic("fork failed");
                if (child == 0) return run(processes[i]);

                log.debug("start: #{d} {s} pid: {d}", .{ i, processes[i][0], child });
                pids[i] = child;
            }
        }

        const exited = std.posix.waitpid(0, 0).pid;
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
    std.posix.nanosleep(0, 100_000_000);

    setproctitle(proc[0]);

    const res = @call(.auto, proc[1], proc[2]);

    if (comptime @typeInfo(@TypeOf(res)) == .ErrorUnion) {
        _ = res catch |e| {
            log.err("{s}", .{@errorName(e)});

            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }

            std.posix.exit(1);
        };
    }

    std.posix.exit(0);
}

fn setproctitle(name: [:0]const u8) void {
    // name includes path so we should always have some extra space
    const dest = std.mem.span(std.os.argv[0]);
    if (std.os.argv.len == 1 and dest.len >= name.len) {
        @memcpy(dest[0..name.len], name);
        dest.ptr[name.len] = 0;
    } else log.debug("Could not rewrite process name {s}\ndest: {s}", .{ name, std.os.argv[0] });
}

fn isTupleOfProcesses(comptime T: type) bool {
    if (!isTuple(T)) return false;

    inline for (@typeInfo(T).Struct.fields) |f| {
        if (!isTuple(f.type)) return false;
        if (@typeInfo(f.type).Struct.fields.len != 3) return false;
    }

    return true;
}

fn isTuple(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .Struct and info.Struct.is_tuple;
}
