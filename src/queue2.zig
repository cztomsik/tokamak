// Notes (before I forget all of this):
// - embedded, no deps, no broker, just mmap() + advisory locks + atomics (TODO)
// - internal NodeIndex is u16 -> 65k msgs hard-limit
// - there are 32 "pages" in bitmap -> 2k msgs soft-limit (could be either bumped or configurable)
// - 64 buckets (+ intrusive chain) should be fine for unique checks, most queues should be below their max capacity
// - TTL is only processed in tick(); TTL=0 is invalid
// - bitmap allocator could use @ctz and read whole word(s) (TODO later)
// ? time could be hashed too?
//
// Crash-resilliency:
// - wheel is the primary store; hash-table and bitmap are rebuildable from the wheel
// - therefore, we only need one atomic for detecting a crash, and proper-locking
//   - and maybe a fence to make sure that wheel append is always the last operation.
// - if there was a crash we can just recover (with `@branchHint(.unlikely)`)
// - I THINK we don't even need the wheel & node.wheel_next to be atomic
// - we don't care about power-failure, OS malfunction, etc. (but could add sync() method to do msync, write checksum, and init() could check that)
// ? ttl=0 can be used for marking uncommited nodes (and we could msync MS_ASYNC from time to time?)

const std = @import("std");
const testing = std.testing;
const expect = std.testing.expect;

const MAGIC: u32 = @bitCast([4]u8{ 'Q', 'U', 'E', '|' });
const VERSION: u32 = 6;
const SLOT_SIZE: usize = 64;
const PAGE_SIZE: usize = 64 * SLOT_SIZE; // 64 slots -> 4096 B
const POOL_OFFSET: usize = @sizeOf(SuperBlock);
const WHEEL_BUCKETS: u32 = 32;

pub const Id = u32; // next_seq << 5 | wbkt
const NodeIndex = enum(u16) { nil = 0, _ };
const JobState = enum(u8) { pending, running };
const SuperBlock = extern struct { header: Header, state: State, _: [32]u8 };
const Header = extern struct { magic: u32, version: u32, _: u32 = 0, n_pages: u32 };

const State = extern struct {
    bitmap: [32]u64, // occupancy tracking
    unique: [64]NodeIndex, // intrusive hash-table
    wheel: [32]NodeIndex, // hashed timing wheel https://www.cs.columbia.edu/~nahum/w6998/papers/sosp87-timing-wheels.pdf
    wheel_pos: i64, // approx. time where we are (may lag behind a bit)
    next_seq: std.atomic.Value(u32),
};

const Node = extern struct {
    id: Id,
    ttl: u32, // 0 = no expiry; N seconds after scheduled_at
    scheduled_at: i64,

    hash_prev: NodeIndex = .nil,
    hash_next: NodeIndex = .nil,
    wheel_prev: NodeIndex = .nil,
    wheel_next: NodeIndex = .nil,

    // Strings are stored sequentially after the Node:
    name_len: u16 = 0, // name: [node_off + @sizeOf(Node) .. + name_len]
    key_len: u16 = 0, //  key:  [name end .. + key_len]
    data_len: u16 = 0, // data: [key end .. + data_len]
    state: JobState,
};

pub const Error = error{ QueueFull, MessageTooLarge, InvalidTTL };

pub const Config = struct {
    path: []const u8 = "/tmp/tk_queue4",
    n_pages: u5 = 16,
    strict: bool = false,
};

pub const Job = struct {
    id: Id,
    name: []const u8,
    key: []const u8,
    data: []const u8,
    scheduled_at: i64,
    ttl: u32,
    state: JobState,
};

pub const Queue = struct {
    fd: std.Io.File,
    mem: []u8,
    header: *Header,
    state: *State,
    pool: []u8,

    comptime {
        std.debug.assert(@sizeOf(NodeIndex) == 2);
        std.debug.assert(@sizeOf(Node) == 32);
        std.debug.assert(SLOT_SIZE >= @sizeOf(Node));
        std.debug.assert(@sizeOf(SuperBlock) == 512);
    }

    pub fn init(io: std.Io, config: Config) !Queue {
        const mmap_size = @sizeOf(SuperBlock) + PAGE_SIZE * config.n_pages;

        const fd = try std.Io.Dir.cwd().createFile(io, config.path, .{ .read = true, .truncate = false });
        errdefer fd.close(io);

        const stat = try fd.stat(io);
        const file_size = stat.size;

        var reset = true;
        if (file_size > 0) {
            var buf: [@sizeOf(Header)]u8 = undefined;
            var fr = fd.readerStreaming(io, &buf);
            const hdr = fr.interface.takeStructPointer(Header) catch return error.InvalidHeader;

            if (hdr.magic == MAGIC and hdr.version == VERSION and file_size == mmap_size) {
                reset = false;
            } else if (config.strict) {
                return error.InvalidHeader;
            }
        } else if (config.strict) {
            return error.InvalidHeader;
        }

        if (reset) try fd.setLength(io, mmap_size);
        const mem = try std.posix.mmap(null, mmap_size, @as(std.posix.PROT, .{ .READ = true, .WRITE = true }), .{ .TYPE = .SHARED }, fd.handle, 0);
        if (reset) @memset(mem, 0);

        const sb: *SuperBlock = @ptrCast(@alignCast(mem.ptr));
        if (reset) {
            sb.header = .{
                .magic = MAGIC,
                .version = VERSION,
                .n_pages = config.n_pages,
            };

            // Mark bit 0 permanently used so slot 0 is never allocated.
            sb.state.bitmap[0] |= 1;
            sb.state.next_seq = .init(1);
        }

        return .{
            .fd = fd,
            .mem = mem,
            .header = &sb.header,
            .state = &sb.state,
            .pool = mem[POOL_OFFSET..],
        };
    }

    pub fn deinit(self: *Queue, io: std.Io) void {
        std.posix.munmap(@alignCast(self.mem));
        self.fd.close(io);
    }

    pub fn schedule(self: *Queue, name: []const u8, key: []const u8, data: []const u8, at: i64) Error!?Id {
        return self.scheduleTTL(name, key, data, at, 300); // 5 minutes default
    }

    pub fn scheduleTTL(self: *Queue, name: []const u8, key: []const u8, data: []const u8, at: i64, ttl: u32) Error!?Id {
        // NOTE: This could be lifted or configurable (in future)
        if (@sizeOf(Node) + name.len + key.len + data.len > PAGE_SIZE) return error.MessageTooLarge;
        if (ttl == 0) return error.InvalidTTL;

        const bkt = if (key.len > 0) hashKey(name, key) else 0;
        const wbkt: u5 = @intCast(@mod(at, WHEEL_BUCKETS));

        // Dedup by (name, key).
        if (key.len > 0) {
            var nidx = self.state.unique[bkt];
            while (nidx != .nil) {
                const n = self.nodeAt(nidx);
                var cur: Cursor = .initAfter(n);
                const n_name = cur.take(n.name_len);
                const n_key = cur.take(n.key_len);
                if (std.mem.eql(u8, n_key, key) and std.mem.eql(u8, n_name, name)) {
                    return null; // duplicate
                }
                nidx = n.hash_next;
            }
        }

        // Allocate the node.
        const needed = @sizeOf(Node) + name.len + key.len + data.len;
        const n_chunks = divCeil(needed, SLOT_SIZE);
        const idx: NodeIndex = @enumFromInt(bm.alloc(self.state.bitmap[0..self.header.n_pages], n_chunks) orelse return error.QueueFull);

        const node = self.nodeAt(idx);
        node.* = .{
            .id = self.state.next_seq.fetchAdd(1, .seq_cst) << 5 | wbkt,
            .ttl = ttl,
            .scheduled_at = at,
            .state = .pending,
            .name_len = @intCast(name.len),
            .key_len = @intCast(key.len),
            .data_len = @intCast(data.len),
        };

        {
            var cur: Cursor = .initAfter(node);
            @memcpy(cur.take(name.len), name);
            @memcpy(cur.take(key.len), key);
            @memcpy(cur.take(data.len), data);
        }

        // Insert into hash table (prepend).
        if (key.len > 0) {
            node.hash_next = self.state.unique[bkt];
            if (node.hash_next != .nil) self.nodeAt(node.hash_next).hash_prev = idx;
            self.state.unique[bkt] = idx;
        }

        // Insert into timing wheel in order (ascending scheduled_at).
        var prev: ?NodeIndex = null;
        var cur = self.state.wheel[wbkt];
        while (cur != .nil) : (cur = self.nodeAt(cur).wheel_next) {
            if (self.nodeAt(cur).scheduled_at >= at) break;
            prev = cur;
        }

        // Splice into doubly-linked list.
        if (prev) |p| {
            self.nodeAt(p).wheel_next = idx;
            node.wheel_prev = p;
        } else {
            self.state.wheel[wbkt] = idx;
            node.wheel_prev = .nil;
        }
        node.wheel_next = cur;
        if (cur != .nil) {
            self.nodeAt(cur).wheel_prev = idx;
        }

        return node.id;
    }

    pub fn tick(self: *Queue, now: i64) ?Id {
        var ticks_delta = std.math.clamp(now - self.state.wheel_pos, 0, WHEEL_BUCKETS - 1);

        while (true) {
            const bkt: usize = @intCast(@mod(self.state.wheel_pos, WHEEL_BUCKETS));
            var nidx = self.state.wheel[bkt];
            while (nidx != .nil) {
                const n = self.nodeAt(nidx);
                nidx = n.wheel_next;

                // Wheel buckets are sorted, so now we know that we can skip to the next one
                if (n.scheduled_at > now) {
                    break;
                }

                // Auto-remove expired
                if (now > (n.scheduled_at + n.ttl)) {
                    self.removeNode(n);
                    continue;
                }

                if (n.state == .pending) {
                    n.state = .running;
                    return n.id;
                }
            }

            if (ticks_delta > 0) {
                ticks_delta -= 1;
                self.state.wheel_pos += 1;
            } else {
                // we should always run at least one bucket (without advancing)
                break;
            }
        }

        // This is not strictly needed, but it's nice to sync our internal clock once in a while.
        self.state.wheel_pos = @max(now, self.state.wheel_pos);

        return null;
    }

    pub fn remove(self: *Queue, id: Id) void {
        const node = self.findNode(id) orelse return;
        self.removeNode(node);
    }

    pub fn clear(self: *Queue) void {
        @memset(@as(*volatile [@sizeOf(State)]u8, @ptrCast(self.state)), 0);
        // Mark bit 0 permanently used so slot 0 is never allocated.
        self.state.bitmap[0] |= 1;
        self.state.next_seq = .init(1);
    }

    pub fn recover(self: *Queue) void {
        // Reset bitmap (slot 0 permanently reserved).
        @memset(self.state.bitmap[0..], 0);
        self.state.bitmap[0] = 1;

        // Reset hash table.
        @memset(self.state.unique[0..], NodeIndex.nil);

        // Reset wheel clock.
        self.state.wheel_pos = 0;

        // Walk every wheel bucket and rebuild bitmap + hash table from nodes.
        var seq_max: u32 = 0;
        var wbkt: usize = 0;
        while (wbkt < WHEEL_BUCKETS) : (wbkt += 1) {
            var nidx = self.state.wheel[wbkt];
            while (nidx != .nil) : (nidx = self.nodeAt(nidx).wheel_next) {
                const n = self.nodeAt(nidx);

                // Track max seq for next_seq.
                const seq = n.id >> 5;
                if (seq > seq_max) seq_max = seq;

                // Mark bitmap slots as used.
                const total = @sizeOf(Node) + n.name_len + n.key_len + n.data_len;
                const n_chunks = divCeil(total, SLOT_SIZE);
                const slot: usize = (@intFromPtr(n) - @intFromPtr(self.pool.ptr)) / SLOT_SIZE;
                bm.mark(self.state.bitmap[0..self.header.n_pages], slot, n_chunks);

                // Re-insert into hash table.
                if (n.key_len != 0) {
                    var cur: Cursor = .initAfter(n);
                    const bkt = hashKey(cur.take(n.name_len), cur.take(n.key_len));
                    n.hash_next = self.state.unique[bkt];
                    if (n.hash_next != .nil) self.nodeAt(n.hash_next).hash_prev = nidx;
                    self.state.unique[bkt] = nidx;
                }
            }
        }

        self.state.next_seq = .init(seq_max + 1);
    }

    pub fn getJob(self: *Queue, id: Id) ?Job {
        const node = self.findNode(id) orelse return null;
        var cur: Cursor = .initAfter(node);
        return .{
            .id = id,
            .name = cur.take(node.name_len),
            .key = cur.take(node.key_len),
            .data = cur.take(node.data_len),
            .scheduled_at = node.scheduled_at,
            .ttl = node.ttl,
            .state = node.state,
        };
    }

    inline fn nodeAt(self: *Queue, idx: NodeIndex) *Node {
        std.debug.assert(idx != .nil);
        const off: usize = @intFromEnum(idx) * SLOT_SIZE;
        return @as(*Node, @ptrCast(@alignCast(&self.pool[off])));
    }

    fn findNode(self: *Queue, id: Id) ?*Node {
        const wbkt = id & 31;
        var nidx = self.state.wheel[wbkt];
        while (nidx != .nil) {
            const node = self.nodeAt(nidx);
            if (node.id == id) return node;
            nidx = node.wheel_next;
        }

        return null;
    }

    fn removeNode(self: *Queue, node: *Node) void {
        // Unlink from hash table
        if (node.key_len != 0) {
            if (node.hash_prev != .nil) {
                self.nodeAt(node.hash_prev).hash_next = node.hash_next;
            } else {
                var cur: Cursor = .initAfter(node);
                const bkt = hashKey(cur.take(node.name_len), cur.take(node.key_len));
                self.state.unique[bkt] = node.hash_next;
            }
            if (node.hash_next != .nil) {
                self.nodeAt(node.hash_next).hash_prev = node.hash_prev;
            }
        }

        // Unlink from timing wheel
        if (node.wheel_prev != .nil) {
            self.nodeAt(node.wheel_prev).wheel_next = node.wheel_next;
        } else {
            const wbkt: u5 = @intCast(@mod(node.scheduled_at, WHEEL_BUCKETS));
            self.state.wheel[wbkt] = node.wheel_next;
        }
        if (node.wheel_next != .nil) {
            self.nodeAt(node.wheel_next).wheel_prev = node.wheel_prev;
        }

        // Free bitmap slots.
        const total = @sizeOf(Node) + node.name_len + node.key_len + node.data_len;
        const n_chunks = divCeil(total, SLOT_SIZE);
        const slot = (@intFromPtr(node) - @intFromPtr(self.pool.ptr)) / SLOT_SIZE;
        bm.free(self.state.bitmap[0..self.header.n_pages], slot, n_chunks);
    }

    fn hashKey(name: []const u8, key: []const u8) u6 {
        var hash: u32 = 2166136261;
        for (name) |b| hash = (hash ^ b) *% 16777619;
        for (key) |b| hash = (hash ^ b) *% 16777619;
        return @truncate(hash);
    }
};

const Cursor = struct {
    ptr: [*]u8,

    fn initAfter(ptr: anytype) Cursor {
        return .{ .ptr = @as([*]u8, @ptrCast(ptr)) + @sizeOf(@TypeOf(ptr.*)) };
    }

    fn take(self: *Cursor, n: usize) []u8 {
        defer self.ptr += n;
        return self.ptr[0..n];
    }
};

fn divCeil(a: usize, b: usize) usize {
    return (a + b - 1) / b;
}

// simple bitmap allocator enclosed in a private namespace
const bm = struct {
    fn alloc(state: []u64, n: usize) ?usize {
        std.debug.assert(n > 0);

        var run: usize = 0;
        var i: usize = 0;
        while (i < state.len * 64) : (i += 1) {
            if ((state[i / 64] >> @intCast(i % 64)) & 1 == 0) {
                run += 1;
                if (run == n) {
                    mark(state, i - (n - 1), n);
                    return i - (n - 1);
                }
            } else {
                run = 0;
            }
        }

        return null;
    }

    fn mark(state: []u64, index: usize, n: usize) void {
        std.debug.assert(n > 0);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const bit = index + i;
            state[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
        }
    }

    fn free(state: []u64, index: usize, n: usize) void {
        std.debug.assert(n > 0 and index + n <= state.len * 64);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const bit = index + i;
            state[bit / 64] &= ~(@as(u64, 1) << @intCast(bit % 64));
        }
    }

    test {
        var state: [3]u64 = @splat(0);

        // alloc one
        const idx1 = alloc(&state, 1).?;
        try expect(idx1 == 0);
        try expect(state[0] == 1);

        // free one
        free(&state, idx1, 1);
        try expect(state[0] == 0);

        // alloc consecutive
        const idx2 = alloc(&state, 3).?;
        try expect(idx2 == 0);
        try expect(state[0] == 0b111);

        // free consecutive
        free(&state, idx2, 3);
        try expect(state[0] == 0);

        // skip used bits
        state[0] = 0b111;
        const idx3 = alloc(&state, 1).?;
        try expect(idx3 == 3);
        try expect(state[0] == 0b1111);

        // word-boundary
        const idx4 = alloc(&state, 64).?;
        try expect(idx4 == 4);
        try expect(state[0] == std.math.maxInt(u64));
        try expect(state[1] == 0b1111);

        // no space
        try expect(alloc(&state, 1_000) == null);
        try expect(alloc(&state, 125) == null);

        // fill entirely
        const idx5 = alloc(&state, 124).?;
        try expect(idx5 == 68);
        try expect(state[0] == std.math.maxInt(u64));
        try expect(state[1] == std.math.maxInt(u64));
        try expect(state[2] == std.math.maxInt(u64));
        try expect(alloc(&state, 1) == null);

        // free in the middle & fill it again
        free(&state, idx3, 1);
        try expect(state[0] == std.math.maxInt(u64) ^ 0b1000);
        try expect(alloc(&state, 2) == null);
        try expect(alloc(&state, 1) == idx3);

        // free everything & check empty
        free(&state, idx5, 124);
        free(&state, idx4, 64);
        free(&state, idx3, 1);
        free(&state, idx2, 3);
        free(&state, idx1, 1);
        try expect(state[0] == 0);
        try expect(state[1] == 0);
        try expect(state[2] == 0);
    }
};

test "schedule, tick, get, remove" {
    var q = try Queue.init(testing.io, .{});
    errdefer q.deinit(testing.io);
    q.clear();

    const id = (try q.schedule("job1", "k1", "data", 10)).?;

    try expect(q.tick(5) == null);
    try expect(q.tick(10) == id);

    const job = q.getJob(id).?;
    try expect(job.id == id);
    try testing.expectEqualStrings("job1", job.name);
    try testing.expectEqualStrings("k1", job.key);
    try testing.expectEqualStrings("data", job.data);
    try expect(job.state == .running);

    q.remove(id);
    try expect(q.getJob(id) == null);
}

test "dedup by (name, key)" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    // Key can be used for de-duping
    const id1 = (try q.schedule("job", "k", "x", 0)).?;
    try expect(try q.schedule("job", "k", "xxx", 0) == null);
    try expect(try q.schedule("job", "k2", "x", 0) != null);
    try expect(try q.schedule("job2", "k", "x", 0) != null);

    // Empty key allows multiple jobs with same name.
    const id_a = (try q.schedule("same", "", "x", 0)).?;
    const id_b = (try q.schedule("same", "", "x", 0)).?;
    try expect(id_a != id_b);

    // Key should be held even when job is running
    _ = q.tick(0); // mark .running
    try expect(try q.schedule("job", "k", "xxx", 0) == null);

    // Remove should release the key
    q.remove(id1);
    try expect(try q.schedule("job", "k", "xxx", 0) != null);
}

test "ordered delivery" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    var ids: [6]Id = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = (try q.schedule("x", "", "x", @intCast(i * 10))).?;
    }

    for (ids, 0..) |id, i| {
        const t: i64 = @intCast(i * 10);
        try expect(q.tick(t) == id);
        try expect(q.tick(t) == null);
        try expect(q.tick(t - 1) == null);
        try expect(q.tick(t + 1) == null);
    }
}

test "queue capacity and full" {
    // Small queue fills quickly (63 available slots)
    var q = try Queue.init(testing.io, .{ .path = "/tmp/tk_small", .n_pages = 1 });
    defer q.deinit(testing.io);
    q.clear();
    for (0..63) |i| _ = try q.schedule("x", "", "x", @intCast(i * 10));
    try expect(q.schedule("x", "", "x", 1000) == error.QueueFull);

    // Default config should have enough space for 1023 msgs
    var q2 = try Queue.init(testing.io, .{});
    defer q2.deinit(testing.io);
    q2.clear();
    for (0..1023) |i| _ = try q2.schedule("x", "", "x", @intCast(i * 10));
    try expect(q2.schedule("x", "", "x", 1000) == error.QueueFull);
}

test "many unique keys" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    var ids: [8]Id = undefined;
    inline for (0..8) |i| {
        const name = std.fmt.comptimePrint("item_{d}", .{i});
        const key = std.fmt.comptimePrint("k_{d}", .{i});
        ids[i] = (try q.schedule(name, key, "data", 0)).?;
    }

    for (0..8) |_| {
        _ = q.tick(0).?;
    }
}

test "persistent attach" {
    const path = "/tmp/tk_queue4_t12";
    {
        var q = try Queue.init(testing.io, .{ .path = path, .n_pages = 2 });
        _ = try q.schedule("persisted", "k", "v", 0);
        q.deinit(testing.io);
    }
    var q = try Queue.init(testing.io, .{ .path = path, .n_pages = 2 });
    defer q.deinit(testing.io);
    const id = q.tick(0).?;
    const j = q.getJob(id).?;
    try testing.expectEqualStrings("persisted", j.name);
    try testing.expectEqualStrings("k", j.key);
    try testing.expectEqualStrings("v", j.data);
    q.remove(id);
}

test "non-strict overwrites garbage" {
    const path = "/tmp/tk_queue4_t13";
    _ = try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "GARBAGE_HEADER_12345" });
    var q = try Queue.init(testing.io, .{ .path = path, .strict = false });
    defer q.deinit(testing.io);
    _ = try q.schedule("fresh", "k", "v", 0);
    try expect(q.tick(0) != null);
}

test "strict rejects version mismatch" {
    const path = "/tmp/tk_queue4_t14";
    _ = std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    {
        var q = try Queue.init(testing.io, .{ .path = path });
        q.header.version = 99;
        q.deinit(testing.io);
    }
    try testing.expectError(error.InvalidHeader, Queue.init(testing.io, .{ .path = path, .strict = true }));
}

test "non-strict accepts empty file" {
    const path = "/tmp/tk_queue4_t15";
    {
        var f = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
        f.close(testing.io);
    }
    var q = try Queue.init(testing.io, .{ .path = path, .strict = false });
    defer q.deinit(testing.io);
    try testing.expect(try q.schedule("ok", "", "", 0) != null);
}

test "strict rejects empty file" {
    const path = "/tmp/tk_queue4_t16";
    _ = std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    {
        var f = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
        f.close(testing.io);
    }
    try testing.expectError(error.InvalidHeader, Queue.init(testing.io, .{ .path = path, .strict = true }));
}

test "strict rejects foreign data" {
    const path = "/tmp/tk_queue4_t17";
    _ = std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    _ = try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "FOREIGN_DATA_HERE!" });
    try testing.expectError(error.InvalidHeader, Queue.init(testing.io, .{ .path = path, .strict = true }));
}

test "clear resets all state" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    const id1 = (try q.schedule("j1", "k1", "d1", 0)).?;
    const id2 = (try q.schedule("j2", "k2", "d2", 10)).?;
    const id3 = (try q.schedule("j3", "", "d3", 20)).?;

    // Verify jobs exist.
    try expect(q.tick(0) == id1);
    _ = q.tick(10);
    q.remove(id1);
    q.remove(id2);
    q.remove(id3);

    // Clear everything.
    q.clear();

    // Wheel and hash should be empty.
    for (q.state.unique) |i| try expect(i == .nil);
    for (q.state.wheel) |i| try expect(i == .nil);
    try expect(q.state.wheel_pos == 0);

    // Data should be cleared?
    // for (q.pool) |b| if (b != 0) return error.UnexpectedData;

    // Old ids should be invalid.
    try expect(q.getJob(id1) == null);
    try expect(q.getJob(id2) == null);
    try expect(q.getJob(id3) == null);

    // New jobs should be schedulable.
    const id4 = (try q.schedule("j1", "k1", "new_data", 0)).?;
    try expect(q.tick(0) == id4);
    const j = q.getJob(id4).?;
    try expect(std.mem.eql(u8, j.data, "new_data"));
    q.remove(id4);
}

test "max message size" {
    const config = Config{ .n_pages = 1 };
    var q = try Queue.init(testing.io, config);
    defer q.deinit(testing.io);
    q.clear();

    // NOTE: first page is shorter
    const data: [PAGE_SIZE - SLOT_SIZE - @sizeOf(Node) - 1]u8 = @splat('x');
    _ = try q.schedule("x", "", &data, 0);
}

test "TTL expiry" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    // disallow TTL=0
    try expect(q.scheduleTTL("invalid", "k", "data", 0, 0) == error.InvalidTTL);

    // Schedule job at t=10 with TTL=5 (expires at t=15).
    _ = try q.scheduleTTL("expire_me", "k", "data", 10, 5);

    // Before scheduled_at: nothing.
    try expect(q.tick(5) == null);
    try expect(q.tick(9) == null);

    // At scheduled_at: should return the job (not yet expired).
    const id = q.tick(10).?;
    const j = q.getJob(id).?;
    try expect(j.ttl == 5);
    try expect(j.state == .running);

    // Clean up.
    q.remove(id);

    // Schedule another that we let expire.
    _ = try q.scheduleTTL("will_expire", "k2", "data", 20, 5);

    // Tick at t=26 (past expiry): job should be auto-removed.
    try expect(q.tick(26) == null);

    // Now the key should be free, allowing reschedule.
    try expect(try q.scheduleTTL("will_expire", "k2", "retry", 30, 300) != null);
}

test "TTL expires running jobs" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    // Job scheduled at t=0 with TTL=5.
    const id = (try q.scheduleTTL("long_job", "k", "data", 0, 5)).?;

    // tick at t=0: returns the job, marks it .running.
    try testing.expectEqual(id, q.tick(0));
    var j = q.getJob(id).?;
    try testing.expectEqual(JobState.running, j.state);

    // tick at t=3: job still alive, nothing returned (already running).
    try testing.expectEqual(null, q.tick(3));
    j = q.getJob(id).?;
    try testing.expectEqual(JobState.running, j.state);

    // Tick far enough forward -> job should be removed. TTL is only guaranteed to strike after full round.
    try testing.expectEqual(null, q.tick(40));
    try testing.expectEqual(null, q.getJob(id));

    // Key freed, can reschedule.
    try testing.expect(try q.scheduleTTL("long_job", "k", "retry", 10, 10) != null);
}

test "multiple expired in same bucket" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    // Expired job at the head of the bucket.
    _ = try q.scheduleTTL("_", "k1", "d", 10, 1); // expires at 11

    // More expired jobs in the same wheel bucket (mod WHEEL_BUCKETS).
    _ = try q.scheduleTTL("a", "ka", "d", 10, 2); // expires at 12
    _ = try q.scheduleTTL("b", "kb", "d", 10, 4); // expires at 14
    const id = (try q.scheduleTTL("c", "kc", "d", 10, 100)).?; // expires at 110

    // At t=15: _, a, b expired and auto-removed; c still valid.
    try expect(q.tick(15) == id);
    q.remove(id);
}

test "tick with backward time after forward jump misses jobs" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    // Schedule jobs far in the future so tick(65) scans without finding them.
    // j1 at t=128 → bucket 0, j2 at t=129 → bucket 1.
    _ = try q.schedule("j1", "", "d1", 128);
    _ = try q.schedule("j2", "", "d2", 129);

    // tick(65): delta=clamp(65-0,0,31)=31 → scans all 32 buckets.
    // Jobs at t=128,129 are past now=65, so nothing dispatched.
    // Loop exhausts ticks, exits, syncs wheel_pos = 65.
    try expect(q.tick(65) == null);
    try expect(q.state.wheel_pos == 65);

    // Now schedule a job in the "past" (before wheel_pos), bucket != 1.
    // t=36 → bucket 4 (36 % 32 = 4).
    const id3 = (try q.schedule("j3", "", "d3", 36)).?;

    // tick(37): delta = clamp(37 - 65, 0, 31) = 0.
    // Only scans bucket 65 % 32 = 1. Job j3 is in bucket 4 → NOT found.
    try expect(q.tick(37) == null);

    // Confirm j3 is still pending (not dispatched, not expired).
    const j3 = q.getJob(id3).?;
    try expect(j3.state == .pending);
    try testing.expectEqualStrings("j3", j3.name);
}

test "wheel_pos wraparound" {
    var q = try Queue.init(testing.io, .{});
    defer q.deinit(testing.io);
    q.clear();

    // Tick to wheel_pos = 1
    _ = q.tick(1);
    try expect(q.state.wheel_pos == 1);

    // Schedule A at bucket 0
    const id_a = (try q.schedule("a", "", "da", 32)).?;
    try expect(q.state.wheel[0] != .nil);

    // Promote A. Stay at wheel_pos = 32 (bucket 0).
    try expect(q.tick(34) == id_a);
    try expect(q.state.wheel_pos == 32);

    // Tick to wheel_pos = 34
    try expect(q.tick(34) == null);
    try expect(q.state.wheel_pos == 34);

    // Schedule B at bucket 1
    const id_b = (try q.schedule("b", "", "db", 65)).?;
    try expect(q.state.wheel[1] != .nil);

    // Find B in bucket 1.
    try expect(q.tick(66) == id_b);
}
