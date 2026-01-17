const std = @import("std");
const mime = @import("mime.zig").mime;

pub const Resource = struct {
    content: []const u8,
    content_type: []const u8,
};

pub const Loader = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*Loader, std.mem.Allocator, []const u8) anyerror!?Resource,
        resolve: *const fn (*Loader, std.mem.Allocator, []const u8) ?[]const u8,
    };

    pub fn load(self: *Loader, arena: std.mem.Allocator, path: []const u8) !?Resource {
        return self.vtable.load(self, arena, path);
    }

    pub fn resolve(self: *Loader, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        return self.vtable.resolve(self, allocator, path);
    }
};

pub const FsLoaderOptions = struct {
    base_dir: []const u8 = ".",
};

pub const FsLoader = struct {
    interface: Loader,
    allocator: std.mem.Allocator,
    base_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, options: FsLoaderOptions) !FsLoader {
        const base_dir = try std.fs.cwd().realpathAlloc(allocator, options.base_dir);
        errdefer allocator.free(base_dir);

        return .{
            .interface = .{
                .vtable = &.{
                    .load = &load,
                    .resolve = &resolve,
                },
            },
            .allocator = allocator,
            .base_dir = base_dir,
        };
    }

    pub fn deinit(self: *FsLoader) void {
        self.allocator.free(self.base_dir);
    }

    fn resolve(loader: *Loader, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *FsLoader = @fieldParentPtr("interface", loader);

        const clean_path = std.mem.trimLeft(u8, path, "/");
        const full_path = std.fs.path.join(allocator, &.{ self.base_dir, clean_path }) catch return null;

        const resolved_path = std.fs.path.resolve(allocator, &.{full_path}) catch {
            allocator.free(full_path);
            return null;
        };
        allocator.free(full_path);

        // Check against path traversal
        if (!std.mem.startsWith(u8, resolved_path, self.base_dir)) {
            allocator.free(resolved_path);
            return null;
        }

        return resolved_path;
    }

    fn load(loader: *Loader, arena: std.mem.Allocator, path: []const u8) !?Resource {
        const resolved = resolve(loader, arena, path) orelse return null;

        const content = std.fs.cwd().readFileAlloc(arena, resolved, std.math.maxInt(usize)) catch |err| {
            return if (err == error.FileNotFound) null else err;
        };

        return .{
            .content = content,
            .content_type = mime(std.fs.path.extension(resolved)),
        };
    }
};
