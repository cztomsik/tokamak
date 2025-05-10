const std = @import("std");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;

const ListenerId = enum(usize) { _ };

const Listener = struct {
    id: ListenerId,
    tid: meta.TypeId,
    handler: *const fn (*Injector) anyerror!void,
};

pub const Bus = struct {
    mutex: std.Thread.Mutex = .{},
    listeners: std.ArrayList(Listener),
    injector: *Injector,

    // NOTE: this could be per-instance, but global id feels better.
    var next_id: std.atomic.Value(usize) = .init(1);

    pub fn init(allocator: std.mem.Allocator, injector: *Injector) Bus {
        return .{
            .listeners = .init(allocator),
            .injector = injector,
        };
    }

    pub fn deinit(self: *Bus) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.listeners.deinit();
    }

    pub fn addListener(self: *Bus, comptime E: type, comptime listener: anytype) !ListenerId {
        self.mutex.lock();
        defer self.mutex.unlock();

        const H = struct {
            fn handleEvent(injector: *Injector) anyerror!void {
                return injector.call(listener, .{});
            }
        };

        const id: ListenerId = @enumFromInt(next_id.fetchAdd(1, .monotonic));

        try self.listeners.append(.{
            .id = id,
            .tid = meta.tid(E),
            .handler = H.handleEvent,
        });

        return id;
    }

    pub fn removeListener(self: *Bus, id: ListenerId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.listeners, 0..) |l, i| {
            if (l.id == id) {
                _ = self.listeners.orderedRemove(i);
                return;
            }
        }
    }

    pub fn dispatch(self: *Bus, event: anytype) !void {
        // TODO: this could dead-lock if anyone calls add/remove/dispatch in the handler
        //       we should probably collect/copy listeners first, and then release the lock
        self.mutex.lock();
        defer self.mutex.unlock();

        const tid = meta.tid(@TypeOf(event));

        var injector = Injector.init(
            &.{.ref(&event)},
            self.injector,
        );

        for (self.listeners.items) |listener| {
            if (listener.tid == tid) {
                // TODO: decide what to do about errors, because even if we
                //       wanted to do something, there might be multiple errors
                //       so we can't just try bus.dispatch() anyway,
                //       and we probably still want to run other handlers too
                _ = listener.handler(&injector) catch {};
            }
        }
    }
};

const t = std.testing;

test {
    var inj = Injector.empty;
    var bus = Bus.init(std.testing.allocator, &inj);
    defer bus.deinit();

    const E = struct { usize };
    const H = struct {
        var handled: bool = false;

        fn handleEvent(ev: E) !void {
            try t.expectEqual(ev[0], 123);
            handled = true;
        }
    };

    _ = try bus.addListener(E, H.handleEvent);
    try bus.dispatch(E{123});
    try t.expect(H.handled);
}
