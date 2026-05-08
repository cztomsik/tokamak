const std = @import("std");
const tk = @import("tokamak");
const Builder = tk.tui.Builder;

pub fn main() !void {
    var cx = try tk.tui.Context.init(std.heap.c_allocator);
    defer cx.deinit();

    while (!state.quit) {
        cx.theme = if (state.dark_mode) .nord else .catppuccin_latte;

        switch (try cx.tick()) {
            .render => |ui| myapp(ui),
            .key => |k| switch (k) {
                .ctrl_c, .escape => break,
                .scroll_up => state.slider_val -= 0.01,
                .scroll_down => state.slider_val += 0.01,
                else => cx.pending_key = k,
            },
            else => cx.next_tick = .render, // animate spinner
        }
    }
}

const State = struct {
    slider_val: f32 = 0.123,
    number_val: i32 = 123,
    text_buf: [64]u8 = ("hello" ++ std.mem.zeroes([59]u8)).*,
    text_len: usize = 5,
    textarea_buf: [256]u8 = ("hello\nmulti-line text area" ++ std.mem.zeroes([230]u8)).*,
    textarea_len: usize = 26,
    flags: [5]bool = @splat(true),
    confirm_reset: bool = false,
    tab_sel: usize = 0,
    tree_sel: usize = 0,
    dark_mode: bool = true,
    quit: bool = false,
};

var state: State = .{};

const tab_items = [_][]const u8{ "Overview", "Settings", "Data" };

fn myapp(ui: Builder) void {
    appbar(ui);

    if (ui.grid(&.{ 30, -1 }, -1)) |g| {
        sidebar(g);
        mainarea(g);
    }

    if (ui.menu(4)) |m| {
        if (m.item(.f1, "Help")) state.flags[0] = !state.flags[0];
        if (m.item(.f5, "Reset")) state.confirm_reset = true;
        if (m.item(.f9, "Dark")) state.dark_mode = !state.dark_mode;
        if (m.item(.f10, "Quit")) state.quit = true;
    }

    if (state.confirm_reset) {
        resetmodal(ui);
    }
}

fn appbar(ui: Builder) void {
    if (ui.panel(3)) |p| {
        if (p.row(&.{ -30, 30 })) |r| {
            r.label("MyApp");

            if (r.tabs(tab_items.len, &state.tab_sel)) |t| {
                for (tab_items) |item| t.item(item);
            }
        }
    }
}

fn sidebar(ui: Builder) void {
    if (ui.panel(-1)) |p| {
        p.header("Navigation");
        p.tree(
            &.{ "Root", "Child A", "Leaf 1", "Leaf 2", "Child B", "Leaf 3" },
            &.{ 0, 1, 2, 2, 1, 2 },
            &state.tree_sel,
        );
    }
}

fn mainarea(ui: Builder) void {
    if (ui.panel(-1)) |p| {
        if (p.grid(&.{ -32, -1 }, -1)) |cols| {
            if (cols.stack(-1)) |col| {
                if (col.collapsible("Buttons", &state.flags[0])) {
                    if (col.button("Show hello")) col.flash("Hello world!");
                    if (col.button("Reset All...")) state.confirm_reset = true;
                }

                if (col.collapsible("Settings", &state.flags[1])) {
                    col.checkbox("Notifications", &state.flags[2]);
                    col.checkbox("Dark mode", &state.dark_mode);
                }

                if (col.collapsible("Inputs", &state.flags[4])) {
                    col.textInput(&state.text_buf, &state.text_len);
                    col.textArea(&state.textarea_buf, &state.textarea_len, 4);
                    col.numberInput(&state.number_val, 1);
                    col.spinner();
                }

                col.separator();

                if (col.row(&.{ 20, 5, -1 })) |row| {
                    row.slider(&state.slider_val, 0.05);
                    row.num(state.slider_val);
                    row.progress(0.7 * state.slider_val);
                }
            }

            if (cols.stack(-1)) |col| {
                col.header("Details");
                col.kvRow("Name: ", "Tokamak");
                col.kvRow("Version: ", "1.0.0");
                col.kvRow("Status: ", "Running");
                col.spacer(1);

                col.header("Select");
                if (col.select(3, &state.tab_sel)) |sel| {
                    sel.item("Option A");
                    sel.item("Option B");
                    sel.item("Option C");
                }

                col.header("Paragraph");
                col.paragraph("Lorem ipsum dolor sit amet. " ** 10, -1);
                col.paragraph("Lorem ipsum dolor sit amet. " ** 10, 2);
            }
        }
    }
}

fn resetmodal(ui: Builder) void {
    if (ui.modal(&state.confirm_reset, "Confirm", 36, 5)) |m| {
        m.label("Do you want to reset all values?");

        if (m.row(&.{ 10, 10 })) |r| {
            if (r.button("Reset")) state = .{};
            if (r.button("Cancel")) state.confirm_reset = false;
        }
    }
}
