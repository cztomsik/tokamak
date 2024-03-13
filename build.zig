const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("tokamak", .{
        .root_source_file = .{ .path = "src/main.zig" },
    });

    const tests = b.addTest(.{ .root_source_file = .{ .path = "src/main.zig" } });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
