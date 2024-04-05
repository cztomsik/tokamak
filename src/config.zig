const std = @import("std");
const log = std.log.scoped(.config);

const DEFAULT_PATH = "config.json";

const ReadOptions = struct {
    path: []const u8 = DEFAULT_PATH,
    cwd: ?std.fs.Dir = null,
    parse: std.json.ParseOptions = .{ .ignore_unknown_fields = true },
};

pub fn read(comptime T: type, allocator: std.mem.Allocator, options: ReadOptions) !std.json.Parsed(T) {
    const cwd = options.cwd orelse std.fs.cwd();

    const file = cwd.openFile(options.path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return std.json.parseFromSlice(T, allocator, "{}", .{}),
        else => return e,
    };
    defer file.close();

    var reader = std.json.reader(allocator, file.reader());
    defer reader.deinit();

    errdefer log.debug("Failed to parse config: {s}", .{reader.scanner.input[reader.scanner.cursor..]});

    return try std.json.parseFromTokenSource(T, allocator, &reader, options.parse);
}

const WriteOptions = struct {
    path: []const u8 = DEFAULT_PATH,
    cwd: ?std.fw.Dir = null,
    stringify: std.json.StringifyOptions = .{ .whitespace = .indent_2 },
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
