const std = @import("std");
const ansi = @import("../ansi.zig");
const Builder = @import("builder.zig").Builder;
const Control = @import("control.zig").Control;

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
    const w: usize = @intCast(ui.peek() orelse return);
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

/// Renders a centered button with a solid background. Returns true when clicked (Enter/Space).
pub fn button(ui: Builder, lab: []const u8) bool {
    const frame = ui.next(1) orelse return false;
    const ctrl = ui.control();

    const f = frame.fg(if (ctrl.focused) .white else .default).bg(if (ctrl.focused) .blue else .cyan);
    f.clear();
    f.hcenter(@intCast(lab.len)).text(lab);
    return ctrl.pressed;
}

/// Renders a checkbox: "[x] Label" or "[ ] Label"
/// When focused, enter/space toggles the value.
pub fn checkbox(ui: Builder, lab: []const u8, checked: *bool) void {
    const frame = ui.next(1) orelse return;
    const ctrl = ui.control();
    ctrl.toggle(checked);

    const w: usize = @intCast(frame.width());
    const f = if (ctrl.focused) frame.fg(.blue) else frame;
    if (w >= 4) {
        f.left(4).text(if (checked.*) "[x] " else "[ ] ");
        f.at(4, 0).text(lab);
    } else if (w >= 3) {
        f.left(3).text(if (checked.*) "[x]" else "[ ]");
    }
}

/// Renders an interactive number input: "[- 42 +]"
/// When focused, left/right keys adjust the value by `step`.
pub fn numberInput(ui: Builder, value: *i32, step: i32) void {
    const frame = ui.next(1) orelse return;
    const ctrl = ui.control();
    const focused = ctrl.focused;
    value.* += @as(i32, ctrl.hdir()) * step;
    ctrl.editNumber(value);

    const w: usize = @intCast(frame.width());
    if (w < 5) return;

    var buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&buf, "{d}", .{value.*}) catch "";
    const inner = w - 4;

    const f = if (focused) frame.fg(.blue) else frame;
    f.left(3).draw(0, 0, if (focused) "[- " else "[  ");
    f.hclear(3, 0, @intCast(inner));
    f.sub(3, 0, @intCast(inner), 1).hcenter(@intCast(num_str.len)).text(num_str);
    f.right(3).draw(0, 0, if (focused) " +]" else "  ]");
}

/// Renders an interactive slider: "[<====o    >] 0.75", value in 0.0..1.0
/// When focused, left/right keys adjust the value by `step`.
pub fn slider(ui: Builder, value: *f32, step: f32) void {
    const frame = ui.next(1) orelse return;
    const ctrl = ui.control();
    const focused = ctrl.focused;
    value.* = std.math.clamp(value.* + @as(f32, @floatFromInt(ctrl.hdir())) * step, 0.0, 1.0);

    const w: usize = @intCast(frame.width());
    if (w < 6) return;
    const track_w: usize = w - 5;
    const clamped: f32 = @max(0.0, @min(1.0, value.*));
    const thumb_pos: usize = @min(@as(usize, @intFromFloat(@as(f32, @floatFromInt(track_w)) * clamped)), track_w - 1);

    const f = if (focused) frame.fg(.blue) else frame;
    const track = f.sub(2, 0, @intCast(track_w), 1);
    f.draw(0, 0, "◄ ");
    if (thumb_pos > 0) track.hline(0, 0, @intCast(thumb_pos));
    track.draw(@intCast(thumb_pos), 0, "●");
    const after = track_w - thumb_pos - 1;
    if (after > 0) track.hline(@intCast(thumb_pos + 1), 0, @intCast(after));
    f.draw(2 + @as(i32, @intCast(track_w)), 0, " ►");
}

/// Renders a horizontal separator line "---".
pub fn separator(ui: Builder) void {
    if (ui.next(1)) |f| f.fill("-");
}

/// Renders an editable single-line text field "[text_]".
/// buf/len are caller-owned; cursor is managed by the Control.
pub fn textInput(ui: Builder, buf: []u8, len: *usize) void {
    const frame = ui.next(1) orelse return;
    const ctrl = ui.control();

    ctrl.editText(buf, len);

    const w: usize = @intCast(frame.width());
    if (w < 3) return;
    const inner = w - 2;
    const txt = buf[0..len.*];
    const input = frame.sub(1, 0, @intCast(inner), 1);

    input.clear();

    if (ctrl.focused) {
        const cursor = ctrl.cursor.*;
        const max_show = if (inner > 0) inner - 1 else 0;
        const show_start = if (cursor > max_show) cursor - max_show else 0;
        const shown = txt[show_start..];
        const f = frame.fg(.blue);
        f.draw(0, 0, "[");
        f.sub(1, 0, @intCast(inner), 1).text(shown);
        f.draw(@as(i32, @intCast(w)) - 1, 0, "]");
        frame.fg(.black).bg(.white).draw(@intCast(1 + cursor - show_start), 0, if (cursor < txt.len) txt[cursor .. cursor + 1] else " ");
    } else {
        frame.draw(0, 0, "[");
        input.text(txt);
        frame.draw(@as(i32, @intCast(w)) - 1, 0, "]");
    }
}

/// Renders a radio-style picker: "(*) Item A" / "( ) Item B".
/// One focus slot; up/down moves selection.
pub fn select(ui: Builder, items: []const []const u8, selected: *usize) void {
    if (items.len == 0) return;
    const first = ui.next(1) orelse return;
    const ctrl = ui.control();
    ctrl.navigate(selected, items.len);

    for (items, 0..) |item, i| {
        const frame = if (i == 0) first else ui.next(1) orelse return;
        const w: usize = @intCast(frame.width());
        if (w < 4) continue;
        const f = if (ctrl.focused and selected.* == i) frame.fg(.blue) else frame;
        f.left(4).text(if (selected.* == i) "(*) " else "( ) ");
        f.at(4, 0).text(item);
    }
}

/// Renders a scrollable list with "> Item" marker for the selected row.
/// One focus slot; up/down moves selection; height controls visible rows.
pub fn list(ui: Builder, items: []const []const u8, selected: *usize, height: i32) void {
    const visible: usize = @intCast(@max(0, height));
    const scroll: usize = if (selected.* >= visible) selected.* - visible + 1 else 0;

    const inner = stack(ui, height) orelse return;
    const ctrl = ui.control();
    ctrl.navigate(selected, items.len);

    var i: usize = scroll;
    while (i < items.len and i < scroll + visible) : (i += 1) {
        const frame = inner.next(1) orelse return;
        const w: usize = @intCast(frame.width());
        if (w < 3) continue;
        const is_sel = i == selected.*;
        const f = if (ctrl.focused and is_sel) frame.fg(.blue) else frame;
        f.left(2).text(if (is_sel) "> " else "  ");
        f.at(2, 0).text(items[i]);
    }
}

/// Renders an animated spinner character cycling |/-\ on each frame.
pub fn spinner(ui: Builder) void {
    if (ui.next(1)) |f| f.drawAnim(0, 0, &.{ "|", "/", "-", "\\" }, ui.ctx.frame);
}

/// Renders text pinned to the bottom row of the screen, outside the layout.
pub fn statusBar(ui: Builder, txt: []const u8) void {
    const root = ui.ctx.stack[0].frame;
    if (root.rect[2] <= 0 or root.rect[3] <= 0) return;
    const bar = root.bottom(1).fg(.black).bg(.cyan);
    bar.clear();
    bar.text(txt);
}

/// Renders a collapsible section header "[v] Title" or "[>] Title".
/// Toggles `open` on Enter/Space. Returns `open.*` so callers can
/// skip rendering content when collapsed.
pub fn header(ui: Builder, lab: []const u8, open: *bool) bool {
    const frame = ui.next(1) orelse return open.*;
    const ctrl = ui.control();
    ctrl.toggle(open);
    const w: usize = @intCast(frame.width());
    const f = if (ctrl.focused) frame.fg(.blue) else frame;
    if (w >= 4) {
        f.left(4).text(if (open.*) "[v] " else "[>] ");
        f.at(4, 0).text(lab);
    } else if (w >= 3) {
        f.left(3).text(if (open.*) "[v]" else "[>]");
    }
    return open.*;
}

/// Renders a centered modal overlay with border, shadow, and title.
/// Breaks out of the normal layout by centering on the root frame.
/// Closes (sets open=false, clears last_key) on Escape and returns null.
/// Returns the inner builder (inset by 1 on all sides) for content.
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
    m.frame.shadow();
    m.frame.clear();
    m.frame.border();
    m.frame.top(1).hcenter(@intCast(title.len)).text(title);
    return m.inset(.{ 1, 1, 1, 1 });
}

/// Renders a progress bar as a background fill, value in 0.0..1.0
pub fn progress(ui: Builder, value: f32) void {
    const frame = ui.next(1) orelse return;
    frame.clear();
    frame.bg(.yellow).hbar(value);
}
