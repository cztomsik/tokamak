const std = @import("std");
const log = std.log.scoped(.config);

const DEFAULT_PATH = "config.json";

const ReadOptions = struct {
    path: []const u8 = DEFAULT_PATH,
    cwd: ?std.fs.Dir = null,
    // TODO: alloc_always should not be overridable
    parse: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    max_bytes: usize = 16 * 1024,
};

pub fn read(comptime T: type, allocator: std.mem.Allocator, options: ReadOptions) !std.json.Parsed(T) {
    const cwd = options.cwd orelse std.fs.cwd();

    const file = cwd.openFile(options.path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return std.json.parseFromSlice(T, allocator, "{}", .{}),
        else => return e,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, options.max_bytes);
    defer allocator.free(contents);

    return try std.json.parseFromSlice(T, allocator, contents, options.parse);
}

const WriteOptions = struct {
    path: []const u8 = DEFAULT_PATH,
    cwd: ?std.fs.Dir = null,
    stringify: std.json.Stringify.Options = .{ .whitespace = .indent_2 },
};

pub fn write(comptime T: type, config: T, options: WriteOptions) !void {
    const cwd = options.cwd orelse std.fs.cwd();

    const file = try cwd.createFile(options.path, .w);
    defer file.close();

    try std.json.stringify(
        config,
        options.stringify,
        file.writer(),
    );
}
