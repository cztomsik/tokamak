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
const util = @import("../util.zig");
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
pub fn text(ui: Builder, txt: []const u8) void {
    if (ui.next(-1, 1)) |f| f.text(txt);
}

/// Alias to text(), at least for now
pub const label = text;

/// Render any numeric value (int or float) as text.
pub fn num(ui: Builder, value: anytype) void {
    ui.text(ui.ctx.fmt("{d}", .{value}));
}

/// Render multiple lines of text, wrapping at width. Reserves the required
/// height from layout (max_height = -1 means auto).
pub fn paragraph(ui: Builder, txt: []const u8, max_height: i32) void {
    const max_w = (ui.peek(-1, 1) orelse return)[2];
    const n_lines: i32 = @intCast(@max(1, util.countLines(txt, @intCast(max_w))));
    if (ui.next(-1, if (max_height == -1) n_lines else @min(n_lines, max_height))) |f| f.text(txt);
}

/// Draws an ASCII border around a stack() and returns the inner scope.
pub fn panel(ui: Builder, height: i32) ?Builder {
    const s = ui.stack(height) orelse return null;
    s.frame.border(.all);
    return s.pad(.{ 1, 1, 1, 1 });
}

/// Render a titled separator: ─ Title ──────
pub fn header(ui: Builder, title: []const u8) void {
    const f = ui.next(-1, 1) orelse return;
    f.splat("─");
    f.text(ui.ctx.fmt("─ {s} ", .{title}));
}

/// Render a collapsible section. Toggles `open` on Enter/Space.
pub fn collapsible(ui: Builder, title: []const u8, open: *bool) bool {
    var f = ui.next(-1, 1) orelse return open.*;
    const ctrl = ui.control(open);
    if (ctrl.pressed()) ctrl.toggle();

    if (ctrl.focused) f.fg = ui.ctx.theme.primary;
    f.text(ui.ctx.fmt("{s} {s}", .{ if (open.*) "▼" else "▶", title }));

    return open.*;
}

/// Render a horizontal separator line.
pub fn separator(ui: Builder) void {
    if (ui.next(-1, 1)) |f| f.splat("-");
}

/// Render a centered button with a solid background. Returns true when clicked (Enter/Space).
pub fn button(ui: Builder, lbl: []const u8) bool {
    const f = ui.next(-1, 1) orelse return false;
    const ctrl = ui.control(@as(*void, undefined));
    const t = ui.ctx.theme;

    f.fill(if (ctrl.focused) t.primary else t.accent);
    f.hcenter(@intCast(lbl.len)).text(lbl);

    if (ctrl.pressed()) {
        ui.ctx.next_tick = .clear;
        return true;
    }

    return false;
}

/// Render a checkbox. Enter/space toggles the value.
pub fn checkbox(ui: Builder, lbl: []const u8, checked: *bool) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control(checked);
    if (ctrl.pressed()) ctrl.toggle();

    if (ctrl.focused) f.fg = ui.ctx.theme.primary;
    f.text(ui.ctx.fmt("{s} {s}", .{ if (checked.*) "[x]" else "[ ]", lbl }));
}

/// Render an interactive number input.
pub fn numberInput(ui: Builder, value: *i32, step: i32) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control(value);
    ctrl.editNumber(); // TODO: This should also take min, max, step
    ctrl.stepNumber(-1000, 1000, step);

    if (ctrl.focused) f.fg = ui.ctx.theme.primary;
    f.text(ui.ctx.fmt("{d}", .{value.*}));
}

/// Render an editable single-line text field.
pub fn textInput(ui: Builder, buf: []u8, len: *usize) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control(len);
    const cur = ui.state(usize, len.*);
    ctrl.editText(buf, len, cur);

    if (ctrl.focused) f.fg = ui.ctx.theme.primary;

    const w: usize = @intCast(f.width());
    const content = buf[0..len.*];

    // Convert byte cursor to display column count.
    const cur_col = utf8ColCount(content[0..cur.*]);
    // Scroll so the cursor is always visible within the frame width.
    const scroll_cols: usize = if (w > 0 and cur_col >= w) cur_col - w + 1 else 0;
    // Find byte offset corresponding to scroll_cols display columns.
    const scroll = utf8ColToByteOffset(content, scroll_cols);
    f.text(content[scroll..]);
    if (ctrl.focused) f.sub(@intCast(cur_col - scroll_cols), 0, 1, 1).fill(f.fg);
}

/// Render an editable multi-line text field with wrapping.
pub fn textArea(ui: Builder, buf: []u8, len: *usize, height: i32) void {
    var f = ui.next(-1, height) orelse return;
    const ctrl = ui.control(len);
    const cur = ui.state(usize, len.*);
    ctrl.editTextArea(buf, len, cur);

    if (ctrl.focused) f.fg = ui.ctx.theme.primary;
    const content = buf[0..len.*];
    f.text(content);

    if (ctrl.focused) {
        const pos = textAreaCursorPos(content[0..cur.*], @intCast(f.width()));
        if (pos[1] < @as(usize, @intCast(f.height()))) {
            f.sub(@intCast(pos[0]), @intCast(pos[1]), 1, 1).fill(f.fg);
        }
    }
}

/// Count the number of display columns in a UTF-8 byte slice (1 codepoint = 1 column).
fn utf8ColCount(bytes: []const u8) usize {
    const view: std.unicode.Utf8View = .initUnchecked(bytes);
    var it = view.iterator();
    var cols: usize = 0;
    while (it.nextCodepoint() != null) cols += 1;
    return cols;
}

/// Return the byte offset into `bytes` that corresponds to `cols` display columns.
fn utf8ColToByteOffset(bytes: []const u8, cols: usize) usize {
    const view: std.unicode.Utf8View = .initUnchecked(bytes);
    var it = view.iterator();
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        if (it.nextCodepoint() == null) break;
    }
    return @intFromPtr(it.peek(1).ptr) - @intFromPtr(bytes.ptr);
}

fn textAreaCursorPos(bytes: []const u8, width: usize) [2]usize {
    var col: usize = 0;
    var line: usize = 0;
    var it = util.wordWrap(bytes, @max(1, width));

    while (it.next()) |chunk| {
        col = utf8ColCount(chunk);
        line += 1;
    }

    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') col = 0;
    return .{ col, line -| 1 };
}

/// Render a radio-style picker. Up/down moves selection.
pub fn select(ui: Builder, n: usize, selected: *usize) ?SelectBuilder {
    const st = ui.stack(@intCast(n)) orelse return null;
    st.container().layout.spacing = 0; // TODO: either remove spacing, or make the API easier to use
    const ctrl = ui.control(selected);
    ctrl.navigate(.{ .up, .down }, n);
    return .{ .ui = st, .ctrl = ctrl };
}

pub const SelectBuilder = struct {
    ui: Builder,
    ctrl: Control(usize),

    pub fn item(self: SelectBuilder, lbl: []const u8) void {
        const i = self.ui.container().index;
        var f = self.ui.next(-1, 1) orelse return;

        if (self.ctrl.focused and self.ctrl.value.* == i) f.fg = self.ui.ctx.theme.primary;
        f.text(self.ui.ctx.fmt("{s} {s}", .{ if (self.ctrl.value.* == i) "(*)" else "( )", lbl }));
    }
};

/// Render an interactive slider. Left/right keys adjust the value by `step`.
pub fn slider(ui: Builder, value: *f32, step: f32) void {
    var f = ui.next(-1, 1) orelse return;
    const ctrl = ui.control(value);
    ctrl.stepNumber(0, 1, step);

    if (ctrl.focused) f.fg = ui.ctx.theme.primary;
    f.draw(0, 0, "◄");
    f.draw(f.width() - 1, 0, "►");

    const track = f.hcenter(f.width() - 4);
    track.hline(0, 0, track.width());
    track.draw(@intFromFloat(value.* * @as(f32, @floatFromInt(track.width()))), 0, "●");
}

/// Render an animated spinner character.
pub fn spinner(ui: Builder) void {
    if (ui.next(-1, 1)) |f| f.drawAnim(0, 0, &.{ "|", "/", "-", "\\" }, ui.ctx.frame);
}

/// Render a progress bar as a background fill, value in 0.0..1.0
pub fn progress(ui: Builder, value: f32) void {
    if (ui.next(-1, 1)) |f| f.hbar(value, .yellow);
}

/// Render a full-screen overlay with z=100, always on top of other content.
pub fn overlay(ui: Builder, width: i32, height: i32) ?Builder {
    const o = ui.pushWithFrame(&.{-1}, ui.ctx.stack[0].frame.center(width, height)) orelse return null;
    o.frame.z = 100;
    return o;
}

/// Render short message in always on top overlay.
pub fn flash(ui: Builder, msg: []const u8) void {
    if (ui.overlay(48, 10)) |o| {
        o.frame.fill(ui.ctx.theme.base3);
        o.frame.border(.all);
        o.frame.sub(1, 1, 46, 8).text(msg);
        o.frame.shadow();
    }
}

/// Render a centered modal overlay with border, shadow, and title.
pub fn modal(ui: Builder, open: *bool, title: []const u8, w: i32, h: i32) ?Builder {
    if (ui.ctx.pending_key != null and ui.ctx.pending_key.? == .escape) {
        open.* = false;
        ui.ctx.pending_key = null;
        return null;
    }

    if (ui.ctx.focus < ui.ctx.n_controls) {
        ui.ctx.focus = @max(ui.ctx.focus, ui.ctx.n_controls); // focus next
        ui.ctx.pending_key = null; // prevent instant interactivity
    }

    const m = ui.pushWithFrame(&.{-1}, ui.ctx.stack[0].frame.center(w, h)) orelse return null;
    m.frame.fill(ui.ctx.theme.base3);
    m.frame.border(.all);
    m.frame.top(1).hcenter(@intCast(title.len)).text(title);
    m.frame.shadow();
    return m.pad(.{ 1, 1, 1, 1 });
}

/// Render text pinned to the bottom row of the screen, outside the layout.
pub fn statusBar(ui: Builder, txt: []const u8) void {
    const t = ui.ctx.theme;
    const f = ui.ctx.stack[0].frame.bottom(1);
    f.fill(t.accent);
    f.with("fg", t.base3).text(txt);
}

/// Begin F1-F10 menu bar pinned to the bottom of the screen.
pub fn menu(ui: Builder, n: u8) ?MenuBuilder {
    const bar = ui.pushEq(n, 1) orelse return null;
    bar.frame.rect = ui.ctx.stack[0].frame.bottom(1).rect;
    bar.frame.fill(ui.ctx.theme.base3);
    return .{ .ui = bar };
}

pub const MenuBuilder = struct {
    ui: Builder,

    pub fn item(self: MenuBuilder, key: Key, txt: []const u8) bool {
        const f = self.ui.next(-1, 1) orelse return false;
        f.left(2).fill(self.ui.ctx.theme.accent);
        f.with("fg", self.ui.ctx.theme.base1).text(@tagName(key));
        f.at(2, 0).with("fg", self.ui.ctx.theme.secondary).text(txt);

        if (self.ui.ctx.pending_key) |k| if (std.meta.eql(k, key)) {
            self.ui.ctx.next_tick = .clear;
            return true;
        };

        return false;
    }
};

/// Render a tab bar. Left/right keys switch tabs.
pub fn tabs(ui: Builder, n: usize, selected: *usize) ?TabBuilder {
    if (n == 0) return null;
    const r = ui.pushEq(@intCast(n), 1) orelse return null;
    const ctrl = ui.control(selected);
    ctrl.navigate(.{ .left, .right }, n);
    return .{ .ui = r, .ctrl = ctrl };
}

pub const TabBuilder = struct {
    ui: Builder,
    ctrl: Control(usize),

    pub fn item(self: TabBuilder, lbl: []const u8) void {
        const i = self.ui.container().index;
        const f = self.ui.next(-1, 1) orelse return;
        const t = self.ui.ctx.theme;
        if (self.ctrl.value.* == i) f.fill(if (self.ctrl.focused) t.primary else t.base2);
        f.at(1, 0).text(lbl);
    }
};

/// Render a key-value pair: "label: value" with the label dimmed.
pub fn kvRow(ui: Builder, lbl: []const u8, value: []const u8) void {
    const f = ui.next(-1, 1) orelse return;
    const lw: i32 = @intCast(lbl.len + 2);
    f.with("fg", ui.ctx.theme.accent).left(lw).text(lbl);
    f.at(lw, 0).draw(0, 0, value);
}

/// Render a tree view with indentation. `depths` gives the nesting level per item.
pub fn tree(ui: Builder, items: []const []const u8, depths: []const u8, selected: *usize) void {
    const ctrl = ui.control(selected);
    ctrl.navigate(.{ .up, .down }, items.len);

    for (items, 0..) |item, i| {
        var f = ui.next(-1, 1) orelse return;
        const depth: i32 = if (i < depths.len) @intCast(depths[i]) else 0;
        const indent = depth * 2;

        if (ctrl.focused and selected.* == i) f.fg = ui.ctx.theme.primary;
        f.at(indent, 0).text(ui.ctx.fmt("{s} {s}", .{ if (selected.* == i) ">" else " ", item }));
    }
}
