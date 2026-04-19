const std = @import("std");
const tk = @import("tokamak");
const Builder = tk.tui.Builder;

pub fn main() !void {
    var cx = try tk.tui.Context.init(std.heap.c_allocator);
    defer cx.deinit();

    while (!state.quit) {
        cx.theme = if (state.dark_mode) tk.tui.Theme.dark else .{};
        const root = try cx.beginFrame();
        myapp(root);
        try cx.endFrame();

        const key = try cx.readKey();
        cx.last_key = key;

        switch (key) {
            .ctrl_c, .escape => break,
            .tab => cx.focus = (cx.focus + 1) % @max(1, cx.n_controls),
            .shift_tab => cx.focus = (cx.focus + cx.n_controls - 1) % @max(1, cx.n_controls),
            else => {},
        }
    }
}

const State = struct {
    slider_val: f32 = 0.123,
    number_val: i32 = 123,
    text_buf: [64]u8 = ("hello" ++ std.mem.zeroes([59]u8)).*,
    text_len: usize = 5,
    flags: [5]bool = @splat(true),
    confirm_reset: bool = false,
    tab_sel: usize = 0,
    tree_sel: usize = 0,
    dark_mode: bool = false,
    quit: bool = false,
};

var state: State = .{};

const select_items = [_][]const u8{ "Option A", "Option B", "Option C" };
const tab_items = [_][]const u8{ "Overview", "Settings", "Data" };

fn myapp(ui: Builder) void {
    if (ui.ctx.theme.bg != .default) ui.frame.fill(ui.ctx.theme.bg);

    appbar(ui);

    if (ui.grid(&.{ 30, -1 }, -1)) |g| {
        sidebar(g);
        mainarea(g);
    }

    if (ui.menu(4)) |m| {
        if (m.menuItem(.f1, "Help")) state.flags[0] = !state.flags[0];
        if (m.menuItem(.f5, "Reset")) state.confirm_reset = true;
        if (m.menuItem(.f9, "Dark")) state.dark_mode = !state.dark_mode;
        if (m.menuItem(.f10, "Quit")) state.quit = true;
    }

    if (state.confirm_reset) {
        resetmodal(ui);
    }
}

fn appbar(ui: Builder) void {
    if (ui.panel(&.{ -30, 30 }, 3)) |p| {
        p.label("MyApp");
        p.tabs(&tab_items, &state.tab_sel);
    }
}

fn sidebar(ui: Builder) void {
    if (ui.panel(&.{-1}, -1)) |p| {
        p.header("Navigation");
        p.tree(
            &.{ "Root", "Child A", "Leaf 1", "Leaf 2", "Child B", "Leaf 3" },
            &.{ 0, 1, 2, 2, 1, 2 },
            &state.tree_sel,
        );
        p.spacer(1);
        p.alert("Connected", .info);
        p.alert("Disk 90% full", .warn);
        p.alert("Service down", .err);
    }
}

fn mainarea(ui: Builder) void {
    if (ui.panel(&.{-1}, -1)) |p| {
        if (p.grid(&.{ -32, -1 }, -1)) |cols| {
            if (cols.stack(-1)) |col| {
                if (col.collapsible("Buttons", &state.flags[0])) {
                    if (col.button("OK")) state.flags[0] = false;
                    if (col.button("Cancel")) state.flags[0] = false;
                    if (col.button("Reset All...")) state.confirm_reset = true;
                }

                if (col.collapsible("Settings", &state.flags[1])) {
                    col.checkbox("Notifications", &state.flags[2]);
                    col.checkbox("Dark mode", &state.dark_mode);
                }

                if (col.collapsible("Inputs", &state.flags[4])) {
                    col.textInput(&state.text_buf, &state.text_len);
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
                col.select(&select_items, &state.tab_sel);
            }
        }
    }
}

fn resetmodal(ui: Builder) void {
    if (ui.modal(&state.confirm_reset, "Confirm", 36, 5)) |m| {
        m.label("Do you want to reset all values?");

        if (m.row(&.{ 10, 10 })) |r| {
            if (r.button("Reset")) {
                state = .{};
            }

            if (r.button("Cancel")) state.confirm_reset = false;
        }
    }
}
