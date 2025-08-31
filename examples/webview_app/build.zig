const std = @import("std");
const tokamak = @import("tokamak");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "webview_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add tokamak
    tokamak.setup(exe, .{
        .embed = &.{
            "public/index.html",
            "public/main.js",
        },
    });

    // Add webview
    const webview = b.dependency("webview", .{});
    exe.linkLibCpp();
    exe.addIncludePath(webview.path("core/include"));
    exe.addCSourceFile(.{ .file = webview.path("core/src/webview.cc"), .flags = &.{ "-std=c++14", "-DWEBVIEW_STATIC" } });

    switch (exe.rootModuleTarget().os.tag) {
        .macos => exe.linkFramework("WebKit"),
        .linux => {
            exe.linkSystemLibrary("gtk+-3.0");
            exe.linkSystemLibrary("webkit2gtk-4.1");
        },
        .windows => {
            exe.linkSystemLibrary("ole32");
            exe.linkSystemLibrary("version");
            exe.linkSystemLibrary("shlwapi");
        },
        else => {},
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
