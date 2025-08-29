const std = @import("std");

// TODO: Id? SlotMap?
pub const Ref = u32;

const Value = struct {
    data: f32,
    grad: f32 = 0,
    backward_fn: ?BackwardFn = null,
};

const BackwardFn = *const fn (cx: *Context, refs: []Ref) void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    values: std.array_list.Managed(Value),
    refs: std.array_list.Managed([]Ref),

    pub fn init(allocator: std.mem.Allocator) !Context {
        return .{
            .allocator = allocator,
            .values = std.array_list.Managed(Value).init(allocator),
            .refs = std.array_list.Managed([]Ref).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        for (self.refs.items) |refs| self.allocator.free(refs);
        self.refs.deinit();
        self.values.deinit();
    }

    pub fn value(self: *Context, val: f32) !Ref {
        const idx = self.values.items.len;
        try self.values.append(.{ .data = val });
        return @intCast(idx);
    }

    pub fn data(self: *Context, ref: Ref) f32 {
        return self.values.items[ref].data;
    }

    pub fn grad(self: *Context, ref: Ref) f32 {
        return self.values.items[ref].grad;
    }

    pub fn apply(self: *Context, comptime Op: type, args: anytype) !Ref {
        // NOTE: This makes cx.apply() 100% type-safe
        const refs = try @call(.auto, Op.init, .{self} ++ args);

        // Save for later
        try self.refs.append(refs);
        const out = refs[0];
        self.values.items[out].backward_fn = Op.backward;

        Op.forward(self, refs);
        return out;
    }

    // Shorthands
    // TODO: unary(T), binary(T) HoCs
    pub fn add(self: *Context, a: Ref, b: Ref) !Ref {
        return self.apply(Add, .{ a, b });
    }

    pub fn mul(self: *Context, a: Ref, b: Ref) !Ref {
        return self.apply(Mul, .{ a, b });
    }

    pub fn pow(self: *Context, a: Ref, exponent: f32) !Ref {
        return self.apply(Pow, .{ a, exponent });
    }

    pub fn relu(self: *Context, a: Ref) !Ref {
        return self.apply(Relu, .{a});
    }

    pub fn tanh(self: *Context, a: Ref) !Ref {
        return self.apply(Tanh, .{a});
    }

    // TODO: The current impl just iterates refs backwards but I think we should
    // have some bitset or sparse set for avoiding double-visit. Also, the order
    // is only incidentically correct but TBH I don't care about that right now.
    // https://research.swtch.com/sparse
    pub fn backward(self: *Context, root: Ref) !void {
        // Zero all gradients
        for (self.values.items) |*val| {
            val.grad = 0;
        }

        self.values.items[root].grad = 1.0;

        var i = self.refs.items.len;
        while (i > 0) {
            i -= 1;
            const refs = self.refs.items[i];
            const out = self.values.items[refs[0]];

            if (out.backward_fn) |fun| {
                fun(self, refs);
            }
        }
    }
};

pub const Add = struct {
    pub fn init(cx: *Context, a: Ref, b: Ref) ![]Ref {
        const refs = try cx.allocator.alloc(Ref, 3);
        refs[0] = try cx.value(0); // out
        refs[1] = a;
        refs[2] = b;
        return refs;
    }

    pub fn forward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 3);
        const out = &cx.values.items[refs[0]];
        const a = cx.values.items[refs[1]];
        const b = cx.values.items[refs[2]];
        out.data = a.data + b.data;
    }

    pub fn backward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 3);
        const out = &cx.values.items[refs[0]];
        cx.values.items[refs[1]].grad += out.grad;
        cx.values.items[refs[2]].grad += out.grad;
    }
};

pub const Mul = struct {
    pub fn init(cx: *Context, a: Ref, b: Ref) ![]Ref {
        const refs = try cx.allocator.alloc(Ref, 3);
        refs[0] = try cx.value(0); // out
        refs[1] = a;
        refs[2] = b;
        return refs;
    }

    pub fn forward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 3);
        const out = &cx.values.items[refs[0]];
        const a = cx.values.items[refs[1]];
        const b = cx.values.items[refs[2]];
        out.data = a.data * b.data;
    }

    pub fn backward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 3);
        const out = &cx.values.items[refs[0]];
        const a = &cx.values.items[refs[1]];
        const b = &cx.values.items[refs[2]];
        a.grad += b.data * out.grad;
        b.grad += a.data * out.grad;
    }
};

pub const Pow = struct {
    pub fn init(cx: *Context, a: Ref, exponent: f32) ![]Ref {
        const refs = try cx.allocator.alloc(Ref, 3);
        refs[0] = try cx.value(0); // out
        refs[1] = a;
        refs[2] = try cx.value(exponent); // exponent
        return refs;
    }

    pub fn forward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 3);
        const out = &cx.values.items[refs[0]];
        const a = cx.values.items[refs[1]];
        const exponent = cx.values.items[refs[2]].data;
        out.data = std.math.pow(f32, a.data, exponent);
    }

    pub fn backward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 3);
        const out = &cx.values.items[refs[0]];
        const input = &cx.values.items[refs[1]];
        const exponent = cx.values.items[refs[2]].data;
        input.grad += exponent * std.math.pow(f32, input.data, exponent - 1) * out.grad;
    }
};

pub const Relu = struct {
    pub fn init(cx: *Context, a: Ref) ![]Ref {
        const refs = try cx.allocator.alloc(Ref, 2);
        refs[0] = try cx.value(0); // out
        refs[1] = a;
        return refs;
    }

    pub fn forward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 2);
        const out = &cx.values.items[refs[0]];
        const a = cx.values.items[refs[1]];
        out.data = if (a.data < 0) 0 else a.data;
    }

    pub fn backward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 2);
        const out = &cx.values.items[refs[0]];
        const input = &cx.values.items[refs[1]];
        input.grad += if (input.data > 0) out.grad else 0;
    }
};

pub const Tanh = struct {
    pub fn init(cx: *Context, a: Ref) ![]Ref {
        const refs = try cx.allocator.alloc(Ref, 2);
        refs[0] = try cx.value(0); // out
        refs[1] = a;
        return refs;
    }

    pub fn forward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 2);
        const out = &cx.values.items[refs[0]];
        const a = cx.values.items[refs[1]];
        const x = a.data;
        const t = (std.math.exp(2 * x) - 1) / (std.math.exp(2 * x) + 1);
        out.data = t;
    }

    pub fn backward(cx: *Context, refs: []Ref) void {
        std.debug.assert(refs.len == 2);
        const out = &cx.values.items[refs[0]];
        const input = &cx.values.items[refs[1]];
        const t = out.data; // already computed
        input.grad += (1 - t * t) * out.grad;
    }
};

test {
    var cx = try Context.init(std.testing.allocator);
    defer cx.deinit();

    const a = try cx.value(2.0);
    const b = try cx.value(-3.0);
    const c = try cx.value(10.0);
    const e = try cx.mul(a, b); // a * b = -6
    const d = try cx.add(e, c); // e + c = 4

    try cx.backward(d);

    try std.testing.expectEqual(@as(f32, 4.0), cx.data(d));
    try std.testing.expectEqual(@as(f32, 1.0), cx.grad(d));
    try std.testing.expectEqual(@as(f32, 1.0), cx.grad(e));
    try std.testing.expectEqual(@as(f32, -3.0), cx.grad(a));
    try std.testing.expectEqual(@as(f32, 2.0), cx.grad(b));
    try std.testing.expectEqual(@as(f32, 1.0), cx.grad(c));
}

test {
    var cx = try Context.init(std.testing.allocator);
    defer cx.deinit();

    const x = try cx.value(-4.0);
    const two = try cx.value(2.0);
    const three = try cx.value(3.0);

    const z = try cx.mul(x, two); // -4 * 2 = -8
    const h = try cx.add(z, two); // -8 + 2 = -6
    const q = try cx.relu(h); // relu(-6) = 0
    const y = try cx.mul(q, three); // 0 * 3 = 0

    try cx.backward(y);

    // Gradient should be 0 because relu blocked it
    try std.testing.expectEqual(@as(f32, 0.0), cx.grad(x));
}

test {
    var cx = try Context.init(std.testing.allocator);
    defer cx.deinit();

    const x = try cx.value(3.0);
    const y = try cx.pow(x, 2.0); // 3^2 = 9

    try std.testing.expectEqual(@as(f32, 9.0), cx.data(y));

    try cx.backward(y);

    // d/dx(x^2) = 2x = 6
    try std.testing.expectEqual(@as(f32, 6.0), cx.grad(x));
}

test {
    var cx = try Context.init(std.testing.allocator);
    defer cx.deinit();

    // Inputs
    const x1 = try cx.value(2.0);
    const x2 = try cx.value(0.0);

    // Weights
    const w1 = try cx.value(-3.0);
    const w2 = try cx.value(1.0);

    // Bias
    const b = try cx.value(6.8813735870195432);

    // Forward pass: o = tanh(x1*w1 + x2*w2 + b)
    const x1w1 = try cx.mul(x1, w1);
    const x2w2 = try cx.mul(x2, w2);
    const x1w1x2w2 = try cx.add(x1w1, x2w2);
    const n = try cx.add(x1w1x2w2, b);
    const o = try cx.tanh(n);

    try cx.backward(o);

    try std.testing.expect(cx.data(o) > 0.7 and cx.data(o) < 0.8);
    try std.testing.expect(cx.grad(x1) < 0);
}
