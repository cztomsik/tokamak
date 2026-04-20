// NOTE: Most widgets here are simple immediate-mode functions, meaning that
// they handle rendering, interactivity, and sometimes return a bool that can be
// used for branching. Container widgets usually return an optional Builder, ie.
// you can do `if (ui.panel(...)) |p| { ... }` pattern and put anything inside.
// Finally, some containers return their own builders, enforcing what can go
// inside, ie. select() returns SelectBuilder, that can only generate select
// items. Most widgets are stateless in the sense that they keep their state
// using user-provided ptrs. Some widgets (like controls) can have their own
// state, like cursor position, and that is stored in the ctx.state "pool",
// which is a bit like React hooks but way more limited.

const std = @import("std");
const Color = @import("color.zig").Color;
const Builder = @import("builder.zig").Builder;
const Control = @import("control.zig").Control;
const Key = @import("context.zig").Key;

/// Render an empty spacer of the given height.
pub fn spacer(ui: Builder, height: i32) void {
    _ = ui.next(-1, height);
}

/// Pushes a single-column layout scope.
pub fn stack(ui: Builder, height: i32) ?Builder {
    return ui.grid(&.{-1}, height);
}

pub fn row(ui: Builder, widths: []const i32) ?Builder {
    return ui.push(widths, 1);
}

/// Pushes a multi-column grid layout scope.
pub fn grid(ui: Builder, widths: []const i32, height: i32) ?Builder {
    return ui.push(widths, height);
}

/// Render a single line of text clipped to the next layout cell's width.
pub fn text(ui: Builder, str: []const u8) void {
    if (ui.next(-1, 1)) |f| f.text(str);
}

/// Alias to text(), at least for now
pub const label = text;

/// Render any numeric value (int or float) as text.
pub fn num(ui: Builder, value: anytype) void {
    var buf: [64]u8 = undefined;
    ui.text(std.fmt.bufPrint(&buf, "{d}", .{value}) catch "");
}

/// Render multiple lines of text, wrapping at width. Reserves the required height from layout.
pub fn paragraph(ui: Builder, str: []const u8) void {
    const w: usize = @intCast((ui.peek(-1, -1) orelse return)[2]);
    var n_lines: i32 = 1;
    var col: usize = 0;
    for (str) |ch| {
        if (ch == '\n') {
            n_lines += 1;
            col = 0;
        } else if (col == w) {
            n_lines += 1;
            col = 1;
        } else {
            col += 1;
        }
    }

    if (ui.next(-1, n_lines)) |f| f.text(str);
}

/// Draws an ASCII border around a grid() and returns the inner scope.
pub fn panel(ui: Builder, widths: []const i32, height: i32) ?Builder {
    const g = ui.grid(widths, height) orelse return null;
    g.frame.border();
    return g.inset(.{ 1, 1, 1, 1 });
}

/// Render a titled separator: ── Title ──────
pub fn header(ui: Builder, title: []const u8) void {
    const f = ui.next(-1, 1) orelse return;
    f.splat("─");
    const len: i32 = @intCast(title.len + 2);
    f.sub(1, 0, len, 1).draw(0, 0, " ");
    f.sub(2, 0, len - 1, 1).text(title);
    f.sub(2 + @as(i32, @intCast(title.len)), 0, 1, 1).draw(0, 0, " ");
}

/// Render a collapsible section. Toggles `open` on Enter/Space.
pub fn collapsible(ui: Builder, lab: []const u8, open: *bool) bool {
    const frame = ui.next(-1, 1) orelse return open.*;
    const ctrl = ui.control();
    ctrl.toggle(open);

    const f = if (ctrl.focused()) frame.fg(ui.ctx.theme.primary) else frame;
    f.draw(0, 0, if (open.*) "▼" else "▶");
    f.at(2, 0).text(lab);

    return open.*;
}

/// Render a horizontal separator line.
pub fn separator(ui: Builder) void {
    if (ui.next(-1, 1)) |f| f.splat("-");
}

/// Render a centered button with a solid background. Returns true when clicked (Enter/Space).
pub fn button(ui: Builder, lab: []const u8) bool {
    const f = ui.next(-1, 1) orelse return false;
    const ctrl = ui.control();
    const t = ui.ctx.theme;

    f.fill(if (ctrl.focused()) t.primary else t.accent);
    f.hcenter(@intCast(lab.len)).text(lab);

    return ctrl.pressed();
}

/// Render a checkbox. Enter/space toggles the value.
pub fn checkbox(ui: Builder, lab: []const u8, checked: *bool) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control();
    ctrl.toggle(checked);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.primary);
    f.left(4).text(if (checked.*) "[x] " else "[ ] ");
    f.at(4, 0).text(lab);
}

/// Render an interactive number input.
pub fn numberInput(ui: Builder, value: *i32, step: i32) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control();
    ctrl.editNumber(value); // TODO: This should also take min, max, step
    ctrl.stepNumber(value, -1000, 1000, step);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.primary);
    var buf: [64]u8 = undefined;
    f.text(std.fmt.bufPrint(&buf, "{d}", .{value.*}) catch "");
}

/// Render an editable single-line text field.
pub fn textInput(ui: Builder, buf: []u8, len: *usize) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control();
    ctrl.editText(buf, len);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.primary);
    f.text(buf[0..len.*]);
    if (ctrl.focused()) f.sub(@intCast(ctrl.cursor.*), 0, 1, 1).fill(ui.ctx.theme.text);
}

/// Render a radio-style picker. Up/down moves selection.
pub fn select(ui: Builder, n: usize, selected: *usize) ?SelectBuilder {
    const st = ui.stack(@intCast(n)) orelse return null;
    const ctrl = ui.control();
    ctrl.navigate(.{ .up, .down }, selected, n);
    return .{ .ui = st, .ctrl = ctrl, .selected = selected };
}

pub const SelectBuilder = struct {
    ui: Builder,
    ctrl: Control,
    selected: *usize,

    pub fn item(self: SelectBuilder, lab: []const u8) void {
        const i = self.ui.container().index;
        var f = self.ui.next(-1, 1) orelse return;
        if (self.ctrl.focused() and self.selected.* == i) f = f.fg(self.ui.ctx.theme.primary);
        f.left(4).text(if (self.selected.* == i) "(*) " else "( ) ");
        f.at(4, 0).text(lab);
    }
};

/// Render an interactive slider. Left/right keys adjust the value by `step`.
pub fn slider(ui: Builder, value: *f32, step: f32) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control();
    ctrl.stepNumber(value, 0, 1, step);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.primary);
    f.draw(0, 0, "◄");
    f.draw(f.width() - 1, 0, "►");

    const track = f.hcenter(f.width() - 4);
    track.hline(0, 0, track.width());
    track.draw(@intFromFloat(value.* * @as(f32, @floatFromInt(track.width()))), 0, "●");
}

/// Render a colored alert with a single line of text.
pub fn alert(ui: Builder, msg: []const u8, level: enum { info, warn, err }) void {
    const f = ui.next(-1, 1) orelse return;

    const color, const icon = switch (level) {
        .info => @as(struct { Color, []const u8 }, .{ .blue, "i" }),
        .warn => .{ .yellow, "!" },
        .err => .{ .red, "x" },
    };

    f.left(1).fg(color).text(icon);
    f.at(2, 0).text(msg);
}

/// Render an animated spinner character.
pub fn spinner(ui: Builder) void {
    if (ui.next(-1, 1)) |f| f.drawAnim(0, 0, &.{ "|", "/", "-", "\\" }, ui.ctx.frame);
}

/// Render a progress bar as a background fill, value in 0.0..1.0
pub fn progress(ui: Builder, value: f32) void {
    if (ui.next(-1, 1)) |f| f.hbar(value, .yellow);
}

/// Render text pinned to the bottom row of the screen, outside the layout.
pub fn statusBar(ui: Builder, txt: []const u8) void {
    const t = ui.ctx.theme;
    const f = ui.ctx.stack[0].frame.bottom(1);
    f.fill(t.accent);
    f.fg(t.base3).text(txt);
}

/// Begin F1-F10 menu bar pinned to the bottom of the screen.
pub fn menu(ui: Builder, n: u8) ?MenuBuilder {
    const bar = ui.pushEq(n, 1) orelse return null;
    bar.frame.rect = ui.ctx.stack[0].frame.bottom(1).rect;
    bar.frame.fill(ui.ctx.theme.base3);
    return .{ .bar = bar };
}

pub const MenuBuilder = struct {
    bar: Builder,

    pub fn item(self: MenuBuilder, key: Key, txt: []const u8) bool {
        const f = self.bar.next(-1, 1) orelse return false;
        f.left(2).fill(self.bar.ctx.theme.accent);
        f.fg(self.bar.ctx.theme.base1).text(@tagName(key));
        f.at(2, 0).fg(self.bar.ctx.theme.secondary).text(txt);

        return if (self.bar.ctx.last_key) |k| std.meta.eql(k, key) else false;
    }
};

/// Render a centered modal overlay with border, shadow, and title.
pub fn modal(ui: Builder, open: *bool, title: []const u8, w: i32, h: i32) ?Builder {
    if (ui.ctx.last_key != null and ui.ctx.last_key.? == .escape) {
        open.* = false;
        ui.ctx.last_key = null;
        return null;
    }

    if (ui.ctx.focus < ui.ctx.n_controls) {
        ui.ctx.focus = @max(ui.ctx.focus, ui.ctx.n_controls); // focus next
        ui.ctx.last_key = null; // prevent instant interactivity
    }

    const m = ui.stack(1) orelse return null;
    m.frame.* = ui.ctx.stack[0].frame.center(w, h);
    m.frame.fill(ui.ctx.theme.base3);
    m.frame.border();
    m.frame.top(1).hcenter(@intCast(title.len)).text(title);
    m.frame.shadow();
    return m.inset(.{ 1, 1, 1, 1 });
}

/// Render a tab bar. Left/right keys switch tabs.
pub fn tabs(ui: Builder, n: usize, selected: *usize) ?TabBuilder {
    if (n == 0) return null;
    const r = ui.pushEq(@intCast(n), 1) orelse return null;
    const ctrl = ui.control();
    ctrl.navigate(.{ .left, .right }, selected, n);
    return .{ .r = r, .ctrl = ctrl, .selected = selected };
}

pub const TabBuilder = struct {
    r: Builder,
    ctrl: Control,
    selected: *usize,

    pub fn item(self: TabBuilder, lab: []const u8) void {
        const i = self.r.container().index;
        const f = self.r.next(-1, 1) orelse return;
        const t = self.r.ctx.theme;
        if (self.selected.* == i) f.fill(if (self.ctrl.focused()) t.primary else t.base2);
        f.at(1, 0).text(lab);
    }
};

/// Render a key-value pair: "label: value" with the label dimmed.
pub fn kvRow(ui: Builder, lab: []const u8, value: []const u8) void {
    const f = ui.next(-1, 1) orelse return;
    const lw: i32 = @intCast(lab.len + 2);
    f.fg(ui.ctx.theme.accent).left(lw).text(lab);
    f.at(lw, 0).draw(0, 0, value);
}

/// Render a tree view with indentation. `depths` gives the nesting level per item.
pub fn tree(ui: Builder, items: []const []const u8, depths: []const u8, selected: *usize) void {
    const ctrl = ui.control();
    ctrl.navigate(.{ .up, .down }, selected, items.len);

    for (items, 0..) |item, i| {
        var f = ui.next(-1, 1) orelse return;
        const depth: i32 = if (i < depths.len) @intCast(depths[i]) else 0;
        const indent = depth * 2;

        if (ctrl.focused() and selected.* == i) f = f.fg(ui.ctx.theme.primary);
        f.draw(indent, 0, if (selected.* == i) "> " else "  ");
        f.at(indent + 2, 0).text(item);
    }
}
