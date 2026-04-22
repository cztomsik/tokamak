// TODO: This was mostly generated using claude-code so it is not yet idiomatic

const std = @import("std");
const tk = @import("tokamak");
const Builder = tk.tui.Builder;
const DirEntry = std.fs.Dir.Entry;

const Panel = struct {
    gpa: std.mem.Allocator,
    path: []u8,
    files: std.ArrayList(DirEntry) = .{},
    selected: usize = 0,

    fn refresh(self: *Panel) !void {
        for (self.files.items) |f| tk.meta.free(self.gpa, f);
        self.files.clearRetainingCapacity();
        self.selected = 0;

        if (!std.mem.eql(u8, self.path, "/")) {
            try self.files.append(self.gpa, .{ .name = try self.gpa.dupe(u8, ".."), .kind = .directory });
        }

        var dir = try std.fs.cwd().openDir(self.path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            try self.files.append(self.gpa, try tk.meta.dupe(self.gpa, entry));
        }

        std.mem.sort(DirEntry, self.files.items, {}, struct {
            fn lt(_: void, a: DirEntry, b: DirEntry) bool {
                if (a.kind != b.kind) return a.kind == .directory;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
    }

    fn current(self: *const Panel) ?DirEntry {
        if (self.files.items.len == 0) return null;
        return self.files.items[self.selected];
    }

    fn enter(self: *Panel, name: []const u8) !void {
        const new_path = if (std.mem.eql(u8, name, ".."))
            try self.gpa.dupe(u8, std.fs.path.dirname(self.path) orelse return)
        else
            try std.fs.path.join(self.gpa, &.{ self.path, name });
        self.gpa.free(self.path);
        self.path = new_path;
        try self.refresh();
    }
};

const Commander = struct {
    panels: [2]Panel,
    active: usize = 0,
    mkdir_buf: [256]u8 = undefined,
    mkdir_len: usize = 0,
    mkdir_active: bool = false,
    quit: bool = false,

    fn init(allocator: std.mem.Allocator, path: []const u8) !Commander {
        var panels = [2]Panel{
            .{ .gpa = allocator, .path = try allocator.dupe(u8, path) },
            .{ .gpa = allocator, .path = try allocator.dupe(u8, path) },
        };
        try panels[0].refresh();
        try panels[1].refresh();
        return .{ .panels = panels };
    }

    fn deinit(self: *Commander) void {
        for (&self.panels) |*p| {
            p.gpa.free(p.path);
            for (p.files.items) |f| p.gpa.free(f.name);
            p.files.deinit(p.gpa);
        }
    }

    fn activePanel(self: *Commander) *Panel {
        return &self.panels[self.active];
    }

    fn inactivePanel(self: *Commander) *Panel {
        return &self.panels[1 - self.active];
    }
};

// --- App state ---

var cmd: Commander = undefined;

// --- UI ---

fn app(ui: Builder) void {
    if (ui.pushEq(2, -1)) |g| {
        filePanel(g, &cmd.panels[0]);
        filePanel(g, &cmd.panels[1]);
    }

    if (cmd.mkdir_active) {
        if (ui.modal(&cmd.mkdir_active, "New directory name", 40, 5)) |m| {
            m.textInput(&cmd.mkdir_buf, &cmd.mkdir_len);
            if (m.row(&.{ 10, 10 })) |r| {
                if (r.button("OK")) {
                    confirmMkdir();
                    cmd.mkdir_active = false;
                    cmd.mkdir_len = 0;
                }
                if (r.button("Cancel")) {
                    cmd.mkdir_active = false;
                    cmd.mkdir_len = 0;
                }
            }
        }

        ui.statusBar("New directory name  (Enter: confirm  Esc: cancel)");
    } else {
        if (ui.menu(6)) |m| {
            // No handlers, but we still want to render as menu items
            _ = m.item(.enter, "open"); // handled in fileList()
            _ = m.item(.tab, "switch"); // fileList() is control, so tab just works

            if (m.item(.f5, "copy")) copyFile();
            if (m.item(.f7, "mkdir")) {
                cmd.mkdir_active = true;
                cmd.mkdir_len = 0;
                @memset(&cmd.mkdir_buf, 0);
                ui.ctx.focus = 2;
            }
            if (m.item(.f8, "delete")) deleteEntry();
            if (m.item(.f10, "quit")) cmd.quit = true;
        }
    }
}

fn filePanel(ui: Builder, panel: *Panel) void {
    if (ui.panel(-1)) |p| {
        p.container().layout.spacing = 0;
        p.label(panel.path);
        p.separator();
        fileList(p, panel, -2);
    }
}

fn fileList(ui: Builder, panel: *Panel, height: i32) void {
    const inner = ui.stack(height) orelse return;
    inner.container().layout.spacing = 0;

    const visible: usize = @intCast(@max(0, inner.frame.height()));
    const scroll: usize = if (panel.selected >= visible) panel.selected - visible + 1 else 0;
    const ctrl = ui.control(&panel.selected);
    ctrl.navigate(.{ .up, .down }, panel.files.items.len);

    if (ctrl.pressed()) {
        openEntry();
    }

    var i: usize = scroll;
    while (i < panel.files.items.len and i < scroll + visible) : (i += 1) {
        var f = inner.next(-1, 1) orelse return;
        const is_sel = i == panel.selected;
        if (ctrl.focused and is_sel) f.fg = ui.ctx.theme.primary;
        if (is_sel) f.fill(ui.ctx.theme.primary);
        const file = panel.files.items[i];
        if (file.kind == .directory) {
            var buf: [258]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "/{s}", .{file.name}) catch file.name;
            if (is_sel) f.fg = ui.ctx.theme.text;
            f.text(name);
        } else {
            f.fg = if (is_sel) ui.ctx.theme.text else ui.ctx.theme.secondary;
            f.text(file.name);
        }
    }
}

// --- Operations ---

fn openEntry() void {
    const panel = cmd.activePanel();
    const file = panel.current() orelse return;
    if (file.kind != .directory) return;
    panel.enter(file.name) catch {};
}

fn copyFile() void {
    const src = cmd.activePanel();
    const dst = cmd.inactivePanel();
    const file = src.current() orelse return;
    if (file.kind == .directory) return;

    const src_path = std.fs.path.join(src.gpa, &.{ src.path, file.name }) catch return;
    defer src.gpa.free(src_path);
    const dst_path = std.fs.path.join(dst.gpa, &.{ dst.path, file.name }) catch return;
    defer dst.gpa.free(dst_path);

    std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch return;
    dst.refresh() catch {};
}

fn deleteEntry() void {
    const panel = cmd.activePanel();
    const file = panel.current() orelse return;
    const path = std.fs.path.join(panel.gpa, &.{ panel.path, file.name }) catch return;
    defer panel.gpa.free(path);

    if (file.kind == .directory) {
        std.fs.cwd().deleteDir(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
    panel.refresh() catch {};
}

fn confirmMkdir() void {
    const name = cmd.mkdir_buf[0..cmd.mkdir_len];
    if (name.len == 0) return;
    const panel = cmd.activePanel();
    const path = std.fs.path.join(panel.gpa, &.{ panel.path, name }) catch return;
    defer panel.gpa.free(path);
    std.fs.cwd().makeDir(path) catch {};
    panel.refresh() catch {};
}

// --- Entry point ---

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    cmd = try Commander.init(allocator, cwd);
    defer cmd.deinit();

    var cx = try tk.tui.Context.init(allocator);
    defer cx.deinit();

    while (!cmd.quit) {
        switch (try cx.tick()) {
            .render => |ui| app(ui),
            .key => |k| switch (k) {
                .ctrl_c => cmd.quit = true,
                else => cx.pending_key = k,
            },
        }
    }
}
