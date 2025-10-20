const std = @import("std");
const mime = @import("mime.zig").mime;

pub const Resource = struct {
    content: []const u8,
    content_type: []const u8,
};

pub const Loader = struct {
    pub const VTable = struct {
        load: *const fn (*Loader, std.mem.Allocator, []const u8) anyerror!?Resource,
        exists: *const fn (*Loader, []const u8) bool,
    };

    vtable: *const VTable,

    pub fn load(self: *Loader, arena: std.mem.Allocator, path: []const u8) !?Resource {
        return self.vtable.load(self, arena, path);
    }

    pub fn exists(self: *Loader, path: []const u8) bool {
        return self.vtable.exists(self, path);
    }
};

pub const FileSystemLoader = struct {
    interface: Loader,
    allocator: std.mem.Allocator,
    base_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !FileSystemLoader {
        return .{
            .interface = .{
                .vtable = &.{
                    .load = &load,
                    .exists = &exists,
                },
            },
            .allocator = allocator,
            .base_dir = try allocator.dupe(u8, base_dir),
        };
    }

    pub fn deinit(self: *FileSystemLoader) void {
        self.allocator.free(self.base_dir);
    }

    fn resolve(self: *FileSystemLoader, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const clean_path = std.mem.trimLeft(u8, path, "/");
        const full_path = std.fs.path.join(allocator, &.{ self.base_dir, clean_path }) catch return null;

        const resolved = std.fs.path.resolve(allocator, &.{full_path}) catch {
            allocator.free(full_path);
            return null;
        };
        allocator.free(full_path);

        if (!std.mem.startsWith(u8, resolved, self.base_dir)) {
            allocator.free(resolved);
            return null;
        }

        return resolved;
    }

    fn load(loader: *Loader, arena: std.mem.Allocator, path: []const u8) !?Resource {
        const self: *FileSystemLoader = @fieldParentPtr("interface", loader);

        const resolved = self.resolve(arena, path) orelse return null;

        const content = std.fs.cwd().readFileAlloc(arena, resolved, std.math.maxInt(usize)) catch |err| {
            return if (err == error.FileNotFound) null else err;
        };

        return .{
            .content = content,
            .content_type = mime(std.fs.path.extension(resolved)),
        };
    }

    fn exists(loader: *Loader, path: []const u8) bool {
        const self: *FileSystemLoader = @fieldParentPtr("interface", loader);

        const resolved = self.resolve(self.allocator, path) orelse return false;
        defer self.allocator.free(resolved);

        std.fs.cwd().access(resolved, .{}) catch return false;
        return true;
    }
};
