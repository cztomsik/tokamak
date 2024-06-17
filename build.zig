const std = @import("std");
const log = std.log.scoped(.tokamak);

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const embed = b.option([]const []const u8, "embed", "Files to embed in the binary") orelse &.{};

    const root = b.addModule("tokamak", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    root.addImport("httpz", httpz.module("httpz"));

    try embedFiles(b, root, @alignCast(embed));

    const tests = b.addTest(.{ .root_source_file = b.path("src/main.zig") });
    tests.root_module.addImport("httpz", httpz.module("httpz"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

// TODO: This is simple and it works, it even recompiles if the files change.
//       However, it's impossible to control when the files are read. So ie. it
//       fails for `npm run build`
fn embedFiles(b: *std.Build, root: *std.Build.Module, files: []const []const u8) !void {
    const options = b.addOptions();
    root.addOptions("embed", options);

    const contents = try b.allocator.alloc([]const u8, files.len);
    for (files, 0..) |path, i| {
        errdefer |e| {
            if (e == error.FileNotFound) {
                log.err("File not found: {s}", .{path});
            }
        }

        contents[i] = try std.fs.cwd().readFileAlloc(
            b.allocator,
            path,
            std.math.maxInt(u32),
        );
    }

    options.addOption([]const []const u8, "files", files);
    options.addOption([]const []const u8, "contents", contents);
}
