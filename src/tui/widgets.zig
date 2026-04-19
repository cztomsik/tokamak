const std = @import("std");
const ansi = @import("../ansi.zig");
const Builder = @import("builder.zig").Builder;
const Control = @import("control.zig").Control;
const Key = @import("context.zig").Key;

/// Renders an empty spacer of the given height.
pub fn spacer(ui: Builder, height: i32) void {
    _ = ui.next(height);
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

/// Renders a single line of text clipped to the next layout cell's width.
pub fn text(ui: Builder, str: []const u8) void {
    if (ui.next(1)) |f| f.text(str);
}

/// Alias to text(), at least for now
pub const label = text;

/// Renders any numeric value (int or float) as text.
pub fn num(ui: Builder, value: anytype) void {
    var buf: [64]u8 = undefined;
    ui.text(std.fmt.bufPrint(&buf, "{d}", .{value}) catch "");
}

/// Renders multiple lines of text, wrapping at width. Reserves the required height from layout.
pub fn paragraph(ui: Builder, str: []const u8) void {
    const w: usize = @intCast((ui.peek(-1) orelse return)[2]);
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

    if (ui.next(n_lines)) |f| f.text(str);
}

/// Draws an ASCII border around a grid() and returns the inner scope.
pub fn panel(ui: Builder, widths: []const i32, height: i32) ?Builder {
    const g = ui.grid(widths, height) orelse return null;
    g.frame.border();
    return g.inset(.{ 1, 1, 1, 1 });
}

/// Renders a titled separator: ── Title ──────
pub fn header(ui: Builder, title: []const u8) void {
    const f = ui.next(1) orelse return;
    f.splat("─");
    const len: i32 = @intCast(title.len + 2);
    f.sub(1, 0, len, 1).draw(0, 0, " ");
    f.sub(2, 0, len - 1, 1).text(title);
    f.sub(2 + @as(i32, @intCast(title.len)), 0, 1, 1).draw(0, 0, " ");
}

/// Renders a collapsible section. Toggles `open` on Enter/Space.
pub fn collapsible(ui: Builder, lab: []const u8, open: *bool) bool {
    const frame = ui.next(1) orelse return open.*;
    const ctrl = ui.control();
    ctrl.toggle(open);

    const f = if (ctrl.focused()) frame.fg(ui.ctx.theme.focus) else frame;
    f.left(4).text(if (open.*) "[v] " else "[>] ");
    f.at(4, 0).text(lab);

    return open.*;
}

/// Renders a horizontal separator line.
pub fn separator(ui: Builder) void {
    if (ui.next(1)) |f| f.splat("-");
}

/// Renders a centered button with a solid background. Returns true when clicked (Enter/Space).
pub fn button(ui: Builder, lab: []const u8) bool {
    const f = ui.next(1) orelse return false;
    const ctrl = ui.control();
    const t = ui.ctx.theme;

    f.fill(if (ctrl.focused()) t.focus else t.accent);
    f.fg(if (ctrl.focused()) t.active else t.fg).hcenter(@intCast(lab.len)).text(lab);

    return ctrl.pressed();
}

/// Renders a checkbox. Enter/space toggles the value.
pub fn checkbox(ui: Builder, lab: []const u8, checked: *bool) void {
    var f = ui.next(1) orelse return;
    const ctrl = ui.control();
    ctrl.toggle(checked);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.focus);
    f.left(4).text(if (checked.*) "[x] " else "[ ] ");
    f.at(4, 0).text(lab);
}

/// Renders an interactive number input.
pub fn numberInput(ui: Builder, value: *i32, step: i32) void {
    var f = ui.next(1) orelse return;
    const ctrl = ui.control();
    ctrl.editNumber(value); // TODO: This should also take min, max, step
    ctrl.stepNumber(value, -1000, 1000, step);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.focus);
    var buf: [64]u8 = undefined;
    f.text(std.fmt.bufPrint(&buf, "{d}", .{value.*}) catch "");
}

/// Renders an editable single-line text field.
pub fn textInput(ui: Builder, buf: []u8, len: *usize) void {
    var f = ui.next(1) orelse return;
    const ctrl = ui.control();
    ctrl.editText(buf, len);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.focus);
    f.text(buf[0..len.*]);
    if (ctrl.focused()) f.sub(@intCast(ctrl.cursor().*), 0, 1, 1).fill(ui.ctx.theme.active);
}

/// Renders a radio-style picker. Up/down moves selection.
pub fn select(ui: Builder, items: []const []const u8, selected: *usize) void {
    const ctrl = ui.control();
    ctrl.navigate(selected, items.len);

    for (items, 0..) |item, i| {
        var f = ui.next(1) orelse return;
        if (ctrl.focused() and selected.* == i) f = f.fg(ui.ctx.theme.focus);
        f.left(4).text(if (selected.* == i) "(*) " else "( ) ");
        f.at(4, 0).text(item);
    }
}

/// Renders an interactive slider. Left/right keys adjust the value by `step`.
pub fn slider(ui: Builder, value: *f32, step: f32) void {
    var f = ui.next(1) orelse return;
    const ctrl = ui.control();
    ctrl.stepNumber(value, 0, 1, step);

    if (ctrl.focused()) f = f.fg(ui.ctx.theme.focus);
    f.draw(0, 0, "◄");
    f.draw(f.width() - 1, 0, "►");

    const track = f.hcenter(f.width() - 4);
    track.hline(0, 0, track.width());
    track.draw(@intFromFloat(value.* * @as(f32, @floatFromInt(track.width()))), 0, "●");
}

/// Render a colored alert with a single line of text.
pub fn alert(ui: Builder, msg: []const u8, level: enum { info, warn, err }) void {
    const f = ui.next(1) orelse return;

    const color, const icon = switch (level) {
        .info => @as(struct { ansi.Color, []const u8 }, .{ .blue, "i" }),
        .warn => .{ .yellow, "!" },
        .err => .{ .red, "x" },
    };

    f.left(1).fg(color).text(icon);
    f.at(2, 0).text(msg);
}

/// Renders an animated spinner character.
pub fn spinner(ui: Builder) void {
    if (ui.next(1)) |f| f.drawAnim(0, 0, &.{ "|", "/", "-", "\\" }, ui.ctx.frame);
}

/// Renders a progress bar as a background fill, value in 0.0..1.0
pub fn progress(ui: Builder, value: f32) void {
    if (ui.next(1)) |f| f.hbar(value, .yellow);
}

/// Renders text pinned to the bottom row of the screen, outside the layout.
pub fn statusBar(ui: Builder, txt: []const u8) void {
    const t = ui.ctx.theme;
    const f = ui.ctx.stack[0].frame.bottom(1);
    f.splat(" "); // TODO: This shouldn't be needed
    f.fill(t.accent);
    f.fg(t.bg).text(txt);
}

/// Begin F1-F10 menu bar pinned to the bottom of the screen.
pub fn menu(ui: Builder, n: u8) ?Builder {
    const bar = ui.pushEq(n, 1) orelse return null;
    bar.frame.rect = ui.ctx.stack[0].frame.bottom(1).rect;
    bar.frame.splat(" "); // TODO: This shouldn't be needed
    bar.frame.fill(ui.ctx.theme.bg.muted());
    return bar;
}

/// Render one F-key menu item.
pub fn menuItem(ui: Builder, key: Key, txt: []const u8) bool {
    const f = ui.next(1) orelse return false;
    f.fill(ui.ctx.theme.bg);
    f.left(2).fill(ui.ctx.theme.accent);
    f.fg(ui.ctx.theme.bg).text(@tagName(key));
    f.at(2, 0).text(txt);

    return if (ui.ctx.last_key) |k| std.meta.eql(k, key) else false;
}

/// Renders a centered modal overlay with border, shadow, and title.
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
    m.frame.border();
    m.frame.top(1).hcenter(@intCast(title.len)).text(title);
    m.frame.shadow();
    return m.inset(.{ 1, 1, 1, 1 });
}

/// Render a tab bar. Left/right keys switch tabs. Returns the selected index.
pub fn tabs(ui: Builder, items: []const []const u8, selected: *usize) void {
    const r = ui.pushEq(@intCast(items.len), 1) orelse return;
    const ctrl = ui.control();
    const t = ui.ctx.theme;
    ctrl.navigate(selected, items.len);

    for (items, 0..) |item, i| {
        const f = r.next(1) orelse return;
        if (selected.* == i) {
            f.fill(if (ctrl.focused()) t.focus else t.accent);
            f.fg(t.active).at(1, 0).text(item);
        } else {
            f.at(1, 0).text(item);
        }
    }
}

/// Renders a key-value pair: "label: value" with the label dimmed.
pub fn kvRow(ui: Builder, lab: []const u8, value: []const u8) void {
    const f = ui.next(1) orelse return;
    const lw: i32 = @intCast(lab.len + 2);
    f.fg(ui.ctx.theme.accent).left(lw).text(lab);
    f.at(lw, 0).draw(0, 0, value);
}

/// Renders a tree view with indentation. `depths` gives the nesting level per item.
pub fn tree(ui: Builder, items: []const []const u8, depths: []const u8, selected: *usize) void {
    const ctrl = ui.control();
    ctrl.navigate(selected, items.len);

    for (items, 0..) |item, i| {
        var f = ui.next(1) orelse return;
        const depth: i32 = if (i < depths.len) @intCast(depths[i]) else 0;
        const indent = depth * 2;
        if (ctrl.focused() and selected.* == i) f = f.fg(ui.ctx.theme.focus);
        if (selected.* == i) {
            f.at(indent, 0).draw(0, 0, "> ");
        } else {
            f.at(indent, 0).draw(0, 0, "  ");
        }
        f.at(indent + 2, 0).text(item);
    }
}
