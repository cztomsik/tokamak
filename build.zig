const std = @import("std");

pub fn build(b: *std.Build) !void {
    const embed = b.option([]const []const u8, "embed", "Files to embed in the binary") orelse &.{};

    const root = b.addModule("tokamak", .{
        .root_source_file = .{ .path = "src/main.zig" },
    });

    try embedFiles(b, root, @alignCast(embed));

    const tests = b.addTest(.{ .root_source_file = .{ .path = "src/main.zig" } });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

fn embedFiles(b: *std.Build, root: *std.Build.Module, files: []const []const u8) !void {
    const options = b.addOptions();
    root.addOptions("embed", options);

    const contents = try b.allocator.alloc([]const u8, files.len);
    for (files, 0..) |path, i| {
        contents[i] = try std.fs.cwd().readFileAlloc(
            b.allocator,
            path,
            std.math.maxInt(u32),
        );
    }

    options.addOption([]const []const u8, "files", files);
    options.addOption([]const []const u8, "contents", contents);
}
