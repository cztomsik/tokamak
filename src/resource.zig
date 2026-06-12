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
    io: std.Io,
    gpa: std.mem.Allocator,
    base_dir: []const u8,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, options: FsLoaderOptions) !FsLoader {
        const base_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, options.base_dir, gpa);
        errdefer gpa.free(base_dir);

        return .{
            .interface = .{
                .vtable = &.{
                    .load = &load,
                    .resolve = &resolve,
                },
            },
            .io = io,
            .gpa = gpa,
            .base_dir = base_dir,
        };
    }

    pub fn deinit(self: *FsLoader) void {
        self.gpa.free(self.base_dir);
    }

    fn resolve(loader: *Loader, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *FsLoader = @fieldParentPtr("interface", loader);

        const clean_path = std.mem.trimStart(u8, path, "/");
        const full_path = std.fs.path.join(arena, &.{ self.base_dir, clean_path }) catch return null;

        const resolved_path = std.fs.path.resolve(arena, &.{full_path}) catch {
            arena.free(full_path);
            return null;
        };
        arena.free(full_path);

        // Check against path traversal
        if (!std.mem.startsWith(u8, resolved_path, self.base_dir)) {
            arena.free(resolved_path);
            return null;
        }

        return resolved_path;
    }

    fn load(loader: *Loader, arena: std.mem.Allocator, path: []const u8) !?Resource {
        const self: *FsLoader = @fieldParentPtr("interface", loader);

        const resolved = resolve(loader, arena, path) orelse return null;

        const content = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, arena, .unlimited) catch |err| {
            return if (err == error.FileNotFound) null else err;
        };
        return .{
            .content = content,
            .content_type = mime(std.fs.path.extension(resolved)),
        };
    }
};
