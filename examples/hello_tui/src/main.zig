const std = @import("std");
const tk = @import("tokamak");
const Builder = tk.tui.Builder;

pub fn main() !void {
    var cx = try tk.tui.Context.init(std.heap.c_allocator);
    defer cx.deinit();

    loop: while (true) {
        const root = try cx.beginFrame();
        myapp(root);
        try cx.endFrame();

        const key = try cx.readKey();
        cx.last_key = key;

        switch (key) {
            .ctrl_c, .escape => break :loop,
            .tab => cx.focus = @mod(cx.focus + 1, @max(1, cx.n_controls)),
            .shift_tab => cx.focus = @mod(cx.focus - 1 + cx.n_controls, @max(1, cx.n_controls)),
            else => {},
        }
    }
}

const State = struct {
    slider_val: f32 = 0.5,
    number_val: i32 = 0,
    text_buf: [64]u8 = std.mem.zeroes([64]u8),
    text_len: usize = 0,
    select_val: usize = 0,
    list_sel: usize = 0,
    flags: [5]bool = @splat(true),
    confirm_reset: bool = false,
};

var state: State = .{};

const select_items = [_][]const u8{ "Option A", "Option B", "Option C" };
const list_items = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta" };

fn myapp(ui: Builder) void {
    // TODO: .bg().fg() is currently returning a new value, maybe it should mutate instead?
    ui.frame.* = ui.frame.bg(.white_muted);
    ui.frame.clear();

    appbar(ui);

    if (ui.grid(&.{ 30, -1 }, -1)) |g| {
        sidebar(g);
        mainarea(g);
    }

    ui.statusBar("Tab/Shift-Tab: focus  |  Arrows: adjust  |  Esc: quit");

    if (state.confirm_reset) {
        resetmodal(ui);
    }
}

fn appbar(ui: Builder) void {
    if (ui.panel(&.{ -10, 10 }, 3)) |p| {
        p.label("MyApp");
        p.label("v1.0");
    }
}

fn sidebar(ui: Builder) void {
    if (ui.panel(&.{-1}, -1)) |p| {
        inline for (1..11) |n| {
            p.label("Item " ++ std.fmt.digits2(n));
        }
    }
}

fn mainarea(ui: Builder) void {
    if (ui.panel(&.{-1}, -1)) |p| {
        if (p.grid(&.{ -32, -1 }, -1)) |cols| {
            if (cols.stack(-1)) |col| {
                if (col.header("Buttons", &state.flags[0])) {
                    if (col.button("OK")) state.flags[0] = false;
                    if (col.button("Cancel")) state.flags[0] = false;
                    if (col.button("Reset All...")) state.confirm_reset = true;
                }

                if (col.header("Settings", &state.flags[1])) {
                    col.checkbox("Notifications", &state.flags[2]);
                    col.checkbox("Dark mode", &state.flags[3]);
                }

                if (col.header("Inputs", &state.flags[4])) {
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
                col.label("-- Paragraph --");
                col.paragraph("Lorem ipsum dolor sit amet. " ** 10);
                col.label("-- Select --");
                col.select(&select_items, &state.select_val);
                col.label("-- List --");
                col.list(&list_items, &state.list_sel, 5);
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
