// TODO: addListener() should only be "armed" in the upcoming dispatch (next or nested)

const std = @import("std");
const meta = @import("meta.zig");
const Injector = @import("injector.zig").Injector;

const ListenerId = enum(usize) { _ };

const Node = struct {
    id: ListenerId,
    tid: meta.TypeId,
    next: ?*Node = null,
    prev: ?*Node = null,
    to_be_removed: bool = false,
    handler: *const fn (*Injector) anyerror!void,

    // NOTE: could be per-bus, but global feels better.
    var next_id: std.atomic.Value(usize) = .init(1);

    fn init(comptime E: type, comptime listener: anytype) Node {
        const H = struct {
            fn handleEvent(injector: *Injector) anyerror!void {
                return injector.call(listener);
            }
        };

        const id: ListenerId = @enumFromInt(next_id.fetchAdd(1, .monotonic));

        return .{
            .id = id,
            .tid = meta.tid(E),
            .handler = H.handleEvent,
        };
    }
};

pub const Bus = struct {
    mutex: std.Thread.Mutex.Recursive = .init,
    injector: *Injector,
    pool: std.heap.MemoryPool(Node),
    head: ?*Node = null,
    tail: ?*Node = null,
    dispatching: usize = 0,
    needs_cleanup: bool = false,

    pub fn init(allocator: std.mem.Allocator, injector: *Injector) Bus {
        return .{
            .injector = injector,
            .pool = .init(allocator),
        };
    }

    pub fn deinit(self: *Bus) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.head = null;
        self.tail = null;
        self.pool.deinit();
    }

    pub fn addListener(self: *Bus, comptime E: type, comptime listener: anytype) !ListenerId {
        self.mutex.lock();
        defer self.mutex.unlock();

        const node: *Node = try self.pool.create();
        node.* = .init(E, listener);

        if (self.tail) |tail| {
            tail.next = node;
            node.prev = tail;
            self.tail = node;
        } else {
            self.head = node;
            self.tail = node;
        }

        return node.id;
    }

    pub fn removeListener(self: *Bus, id: ListenerId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var current = self.head;
        while (current) |node| : (current = node.next) {
            if (node.id == id) {
                if (self.dispatching > 0) {
                    node.to_be_removed = true;
                    self.needs_cleanup = true;
                    return;
                }

                return self.removeNode(node);
            }
        }
    }

    fn removeNode(self: *Bus, node: *Node) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }

        self.pool.destroy(node);
    }

    pub fn dispatch(self: *Bus, event: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.dispatching += 1;
        defer self.dispatching -= 1;

        const tid = meta.tid(@TypeOf(event));

        var injector = Injector.init(
            &.{ .ref(self), .ref(&event) },
            self.injector,
        );

        var current = self.head;
        while (current) |node| : (current = node.next) {
            if (node.tid == tid and !node.to_be_removed) {
                // TODO: decide what to do about errors, because even if we
                //       wanted to do something, there might be multiple errors
                //       so we can't just try bus.dispatch() anyway,
                //       and we probably still want to run other handlers too
                _ = node.handler(&injector) catch {};
            }
        }

        if (self.dispatching == 1 and self.needs_cleanup) {
            self.cleanup();
            self.needs_cleanup = false;
        }
    }

    fn cleanup(self: *Bus) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next; // Save before node goes invalid

            if (node.to_be_removed) {
                self.removeNode(node);
            }

            current = next;
        }
    }
};

test "basic usage" {
    var inj = Injector.empty;
    var bus = Bus.init(std.testing.allocator, &inj);
    defer bus.deinit();

    const E = struct { usize };
    const H = struct {
        var handled: bool = false;

        fn handleEvent(ev: E) !void {
            try std.testing.expectEqual(ev[0], 123);
            handled = true;
        }
    };

    _ = try bus.addListener(E, H.handleEvent);
    try bus.dispatch(E{123});
    try std.testing.expect(H.handled);
}

test "recursion" {
    var inj = Injector.empty;
    var bus = Bus.init(std.testing.allocator, &inj);
    defer bus.deinit();

    const E = struct { usize };
    const H = struct {
        var count: usize = 0;

        fn handleEvent(b: *Bus, ev: E) !void {
            if (ev[0] < 10) {
                count += 1;
                try b.dispatch(E{ev[0] + 1});
            }
        }
    };

    _ = try bus.addListener(E, H.handleEvent);
    try bus.dispatch(E{0});
    try std.testing.expectEqual(10, H.count);
}

test "add/remove" {
    var inj = Injector.empty;
    var bus = Bus.init(std.testing.allocator, &inj);
    defer bus.deinit();

    const E = struct {};
    const H = struct {
        var count: usize = 0;

        fn handleEvent(_: E) !void {
            count += 1;
        }
    };

    const l1 = try bus.addListener(E, H.handleEvent);
    try bus.dispatch(E{});
    try std.testing.expectEqual(1, H.count);

    const l2 = try bus.addListener(E, H.handleEvent);
    try bus.dispatch(E{});
    try std.testing.expectEqual(3, H.count);

    bus.removeListener(l1);
    try bus.dispatch(E{});
    try std.testing.expectEqual(4, H.count);

    bus.removeListener(l2);
    try bus.dispatch(E{});
    try std.testing.expectEqual(4, H.count);
}

test "remove itself should not segfault" {
    var inj = Injector.empty;
    var bus = Bus.init(std.testing.allocator, &inj);
    defer bus.deinit();

    const E = struct { ListenerId };
    const H = struct {
        var count: usize = 0;

        fn handleEvent(b: *Bus, ev: E) !void {
            count += 1;
            b.removeListener(ev[0]);
        }
    };

    const lid = try bus.addListener(E, H.handleEvent);
    try bus.dispatch(E{lid});
    try bus.dispatch(E{lid});
    try std.testing.expectEqual(1, H.count);
}
