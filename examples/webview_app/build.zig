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
    exe.root_module.link_libcpp = true;
    exe.root_module.addIncludePath(webview.path("core/include"));
    exe.root_module.addCSourceFile(.{ .file = webview.path("core/src/webview.cc"), .flags = &.{ "-std=c++14", "-DWEBVIEW_STATIC" } });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(webview.path("core/include"));
    exe.root_module.addImport("c", translate_c.createModule());

    switch (exe.rootModuleTarget().os.tag) {
        .macos => exe.root_module.linkFramework("WebKit", .{}),
        .linux => {
            exe.root_module.linkSystemLibrary("gtk+-3.0", .{});
            exe.root_module.linkSystemLibrary("webkit2gtk-4.1", .{});
        },
        .windows => {
            exe.root_module.linkSystemLibrary("ole32", .{});
            exe.root_module.linkSystemLibrary("version", .{});
            exe.root_module.linkSystemLibrary("shlwapi", .{});
        },
        else => {},
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
