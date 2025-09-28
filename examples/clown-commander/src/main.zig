// TODO: This was mostly generated using claude-code so it's not really idiomatic yet

const std = @import("std");
const tk = @import("tokamak");

const FileInfo = struct {
    name: []const u8,
    is_dir: bool,
    size: u64,
};

const Panel = struct {
    path: []u8,
    files: std.ArrayList(FileInfo),
    selected: usize,

    fn init(allocator: std.mem.Allocator, path: []const u8) !Panel {
        var panel = Panel{
            .path = try allocator.dupe(u8, path),
            .files = std.ArrayList(FileInfo){},
            .selected = 0,
        };
        try panel.refresh(allocator);
        return panel;
    }

    fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.files.items) |file| {
            allocator.free(file.name);
        }
        self.files.deinit(allocator);
    }

    fn refresh(self: *Panel, allocator: std.mem.Allocator) !void {
        for (self.files.items) |file| {
            allocator.free(file.name);
        }
        self.files.clearRetainingCapacity();
        self.selected = 0;

        var dir = std.fs.cwd().openDir(self.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => return,
            else => return err,
        };
        defer dir.close();

        if (!std.mem.eql(u8, self.path, "/")) {
            const parent_info = FileInfo{
                .name = try allocator.dupe(u8, ".."),
                .is_dir = true,
                .size = 0,
            };
            try self.files.append(allocator, parent_info);
        }

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            const name = try allocator.dupe(u8, entry.name);
            const file_info = FileInfo{
                .name = name,
                .is_dir = entry.kind == .directory,
                .size = if (entry.kind == .file) blk: {
                    const file = dir.openFile(entry.name, .{}) catch break :blk 0;
                    defer file.close();
                    const stat = file.stat() catch break :blk 0;
                    break :blk stat.size;
                } else 0,
            };
            try self.files.append(allocator, file_info);
        }

        std.mem.sort(FileInfo, self.files.items, {}, struct {
            fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
    }

    fn navigateUp(self: *Panel) void {
        if (self.selected > 0) {
            self.selected -= 1;
        }
    }

    fn navigateDown(self: *Panel) void {
        if (self.selected + 1 < self.files.items.len) {
            self.selected += 1;
        }
    }

    fn getCurrentFile(self: *Panel) ?FileInfo {
        if (self.files.items.len == 0) return null;
        return self.files.items[self.selected];
    }
};

const Commander = struct {
    allocator: std.mem.Allocator,
    left: Panel,
    right: Panel,
    active: enum { left, right },

    fn init(allocator: std.mem.Allocator) !Commander {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);

        return Commander{
            .allocator = allocator,
            .left = try Panel.init(allocator, cwd),
            .right = try Panel.init(allocator, cwd),
            .active = .left,
        };
    }

    fn deinit(self: *Commander) void {
        self.left.deinit(self.allocator);
        self.right.deinit(self.allocator);
    }

    fn getActivePanel(self: *Commander) *Panel {
        return switch (self.active) {
            .left => &self.left,
            .right => &self.right,
        };
    }

    fn getInactivePanel(self: *Commander) *Panel {
        return switch (self.active) {
            .left => &self.right,
            .right => &self.left,
        };
    }
};

const App = struct {
    fn run() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var commander = try Commander.init(allocator);
        defer commander.deinit();

        // Use TUI context
        const ctx = try tk.tui.Context.init(allocator);
        defer ctx.deinit();

        while (true) {
            try displayPanels(&commander, ctx);
            try ctx.flush();

            const key = try ctx.readKey();

            switch (key) {
                .char => |c| switch (c) {
                    'q' => break,
                    'c' => try copyFile(&commander),
                    'd' => try deleteFile(&commander),
                    'm' => try createDirectory(&commander, ctx),
                    else => {},
                },
                .tab => commander.active = if (commander.active == .left) .right else .left,
                .up => commander.getActivePanel().navigateUp(),
                .down => commander.getActivePanel().navigateDown(),
                .left => commander.active = .left,
                .right => commander.active = .right,
                .enter => try enterDirectory(&commander),
                .f5 => try copyFile(&commander), // F5 for copy (like MC)
                .f7 => try createDirectory(&commander, ctx), // F7 for mkdir (like MC)
                .f8 => try deleteFile(&commander), // F8 for delete (like MC)
                else => {},
            }
        }
    }
};

fn displayPanels(commander: *Commander, ctx: *tk.tui.Context) !void {
    try ctx.clear();

    const left_active = commander.active == .left;
    const right_active = commander.active == .right;

    const horizontal_line = "─" ** 38;
    try ctx.print("┌{s}┬{s}┐", .{ horizontal_line, horizontal_line });
    try ctx.println("", .{});

    // Use truncateEnd for paths
    const left_path = tk.util.truncateEnd(commander.left.path, 38);
    const right_path = tk.util.truncateEnd(commander.right.path, 38);

    try ctx.println("│{s:<38}│{s:<38}│", .{ left_path, right_path });
    try ctx.println("├{s}┼{s}┤", .{ horizontal_line, horizontal_line });

    const max_files = 20;
    for (0..max_files) |i| {
        const left_file = if (i < commander.left.files.items.len) commander.left.files.items[i] else null;
        const right_file = if (i < commander.right.files.items.len) commander.right.files.items[i] else null;

        const left_marker = if (left_active and i == commander.left.selected) ">" else " ";
        const right_marker = if (right_active and i == commander.right.selected) ">" else " ";

        const left_text = if (left_file) |file|
            if (file.is_dir)
                std.fmt.allocPrint(std.heap.page_allocator, "{s}[{s}]", .{ left_marker, file.name }) catch ""
            else
                std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ left_marker, file.name }) catch ""
        else
            "";

        const right_text = if (right_file) |file|
            if (file.is_dir)
                std.fmt.allocPrint(std.heap.page_allocator, "{s}[{s}]", .{ right_marker, file.name }) catch ""
            else
                std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ right_marker, file.name }) catch ""
        else
            "";

        try ctx.println("│{s:<38}│{s:<38}│", .{ left_text[0..@min(left_text.len, 38)], right_text[0..@min(right_text.len, 38)] });

        if (left_file != null) std.heap.page_allocator.free(left_text);
        if (right_file != null) std.heap.page_allocator.free(right_text);
    }

    try ctx.println("└{s}┴{s}┘", .{ horizontal_line, horizontal_line });
    try ctx.println("↑↓: navigate  Tab/←→: switch panels  Enter: enter dir  F5/c: copy  F7/m: mkdir  F8/d: delete  q: quit", .{});
}

fn enterDirectory(commander: *Commander) !void {
    const panel = commander.getActivePanel();
    const file = panel.getCurrentFile() orelse return;

    if (!file.is_dir) return;

    if (std.mem.eql(u8, file.name, "..")) {
        const parent = std.fs.path.dirname(panel.path) orelse return;
        const new_path = try commander.allocator.dupe(u8, parent);
        commander.allocator.free(panel.path);
        panel.path = new_path;
    } else {
        const new_path = try std.fs.path.join(commander.allocator, &.{ panel.path, file.name });
        commander.allocator.free(panel.path);
        panel.path = new_path;
    }

    try panel.refresh(commander.allocator);
}

fn copyFile(commander: *Commander) !void {
    const src_panel = commander.getActivePanel();
    const dst_panel = commander.getInactivePanel();
    const file = src_panel.getCurrentFile() orelse return;

    if (file.is_dir) return;

    const src_path = try std.fs.path.join(commander.allocator, &.{ src_panel.path, file.name });
    defer commander.allocator.free(src_path);

    const dst_path = try std.fs.path.join(commander.allocator, &.{ dst_panel.path, file.name });
    defer commander.allocator.free(dst_path);

    std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch |err| {
        std.debug.print("Copy failed: {}\n", .{err});
        const stdin = std.fs.File.stdin();
        var buf: [1]u8 = undefined;
        _ = stdin.read(&buf) catch {};
        return;
    };

    try dst_panel.refresh(commander.allocator);
}

fn deleteFile(commander: *Commander) !void {
    const panel = commander.getActivePanel();
    const file = panel.getCurrentFile() orelse return;

    const file_path = try std.fs.path.join(commander.allocator, &.{ panel.path, file.name });
    defer commander.allocator.free(file_path);

    if (file.is_dir) {
        std.fs.cwd().deleteDir(file_path) catch |err| {
            std.debug.print("Delete failed: {}\n", .{err});
            const stdin = std.fs.File.stdin();
            var buf: [1]u8 = undefined;
            _ = stdin.read(&buf) catch {};
            return;
        };
    } else {
        std.fs.cwd().deleteFile(file_path) catch |err| {
            std.debug.print("Delete failed: {}\n", .{err});
            const stdin = std.fs.File.stdin();
            var buf: [1]u8 = undefined;
            _ = stdin.read(&buf) catch {};
            return;
        };
    }

    try panel.refresh(commander.allocator);
}

fn createDirectory(commander: *Commander, ctx: *tk.tui.Context) !void {
    const panel = commander.getActivePanel();

    // Show prompt at bottom of screen
    const horizontal_line = "─" ** 38;
    try ctx.println("└{s}┴{s}┘", .{ horizontal_line, horizontal_line });
    try ctx.print("Enter directory name: ", .{});
    try ctx.flush();

    // Read directory name
    var name_buf: [256]u8 = undefined;
    const dir_name = try ctx.readLine(&name_buf) orelse return; // User cancelled

    if (dir_name.len == 0) return; // Empty name, cancel

    const dir_path = try std.fs.path.join(commander.allocator, &.{ panel.path, dir_name });
    defer commander.allocator.free(dir_path);

    std.fs.cwd().makeDir(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => return, // Directory already exists
        else => return err,
    };

    try panel.refresh(commander.allocator);
}

pub fn main() !void {
    try tk.app.run(App.run, &.{App});
}
