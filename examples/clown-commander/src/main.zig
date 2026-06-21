// TODO: This was semi-generated using LLM so it is not yet idiomatic

const std = @import("std");
const tk = @import("tokamak");
const Builder = tk.tui.Builder;
const DirEntry = std.Io.Dir.Entry;

const cwd = std.Io.Dir.cwd;

const Panel = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []u8,
    files: std.ArrayList(DirEntry) = .empty,
    selected: usize = 0,

    fn refresh(self: *Panel) !void {
        for (self.files.items) |f| tk.meta.free(self.gpa, f);
        self.files.clearRetainingCapacity();
        self.selected = 0;

        if (!std.mem.eql(u8, self.path, "/")) {
            try self.files.append(self.gpa, .{ .name = try self.gpa.dupe(u8, ".."), .kind = .directory, .inode = 0 });
        }

        const dir = try cwd().openDir(self.io, self.path, .{ .iterate = true });
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
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

    fn init(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Commander {
        var panels = [2]Panel{
            .{ .io = io, .gpa = gpa, .path = try gpa.dupe(u8, path) },
            .{ .io = io, .gpa = gpa, .path = try gpa.dupe(u8, path) },
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
        filePanel(g, &cmd, &cmd.panels[0]);
        filePanel(g, &cmd, &cmd.panels[1]);
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
            if (m.item(.enter, "open")) openEntry();
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

fn filePanel(ui: Builder, commander: *Commander, panel: *Panel) void {
    if (ui.panel(-1)) |p| {
        p.container().layout.spacing = 0;
        p.label(panel.path);
        p.separator();
        fileList(p, commander, panel, -2);
    }
}

fn fileList(ui: Builder, commander: *Commander, panel: *Panel, height: i32) void {
    const inner = ui.stack(height) orelse return;
    inner.container().layout.spacing = 0;

    const visible: usize = @intCast(@max(0, inner.frame.height()));
    const scroll: usize = if (panel.selected >= visible) panel.selected - visible + 1 else 0;
    const ctrl = ui.control(&panel.selected);
    ctrl.navigate(.{ .up, .down }, panel.files.items.len);

    if (ctrl.focused) {
        commander.active = if (panel == &commander.panels[0]) 0 else 1;
    }

    var i: usize = scroll;
    while (i < panel.files.items.len and i < scroll + visible) : (i += 1) {
        var f = inner.next(-1, 1) orelse return;
        const is_sel = i == panel.selected;
        if (ctrl.focused and is_sel) f.fg = .primary;
        if (is_sel) f.fill(.primary);
        const file = panel.files.items[i];
        if (file.kind == .directory) {
            if (is_sel) f.fg = .text;
            f.text(ui.ctx.fmt("/{s}", .{file.name}));
        } else {
            f.fg = if (is_sel) .text else .secondary;
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

    cwd().copyFile(src_path, cwd(), dst_path, src.io, .{}) catch return;
    dst.refresh() catch {};
}

fn deleteEntry() void {
    const panel = cmd.activePanel();
    const file = panel.current() orelse return;
    const path = std.fs.path.join(panel.gpa, &.{ panel.path, file.name }) catch return;
    defer panel.gpa.free(path);

    if (file.kind == .directory) {
        std.Io.Dir.deleteDir(cwd(), panel.io, path) catch {};
    } else {
        std.Io.Dir.deleteFile(cwd(), panel.io, path) catch {};
    }
    panel.refresh() catch {};
}

fn confirmMkdir() void {
    const name = cmd.mkdir_buf[0..cmd.mkdir_len];
    if (name.len == 0) return;
    const panel = cmd.activePanel();
    const path = std.fs.path.join(panel.gpa, &.{ panel.path, name }) catch return;
    defer panel.gpa.free(path);
    std.Io.Dir.createDir(cwd(), panel.io, path, .default_dir) catch {};
    panel.refresh() catch {};
}

// --- Entry point ---

pub fn main(init: std.process.Init) !void {
    const cwd_path = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd_path);

    cmd = try Commander.init(init.io, init.gpa, cwd_path);
    defer cmd.deinit();

    var cx = try tk.tui.Context.init(init.io, init.gpa);
    defer cx.deinit();

    while (!cmd.quit) {
        switch (try cx.tick()) {
            .render => |ui| app(ui),
            .key => |k| switch (k) {
                .ctrl_c => cmd.quit = true,
                else => cx.pending_key = k,
            },
            else => {},
        }
    }
}
