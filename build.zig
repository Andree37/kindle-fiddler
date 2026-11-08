const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });

    // The app.
    const noface = b.addExecutable(.{
        .name = "noface",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
            .link_libc = true,
        }),
    });
    addFontAndImageCode(b, noface.root_module);
    b.installArtifact(noface);

    // Development tools, kept out of the app. Built with `zig build tools`.
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    addFontAndImageCode(b, core);

    const tools_step = b.step("tools", "Build the development tools in tools/");
    for ([_][]const u8{ "latency", "kfxstat", "pagetest", "panelshot", "touchsim", "fbcap" }) |name| {
        const tool = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
                .target = target,
                .optimize = .ReleaseFast,
                .strip = true,
                .link_libc = true,
            }),
        });
        tool.root_module.addImport("core", core);
        tools_step.dependOn(&b.addInstallArtifact(tool, .{}).step);
    }

    const test_step = b.step("test", "Run unit tests on the host");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addFontAndImageCode(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("third_party"));
    module.addCSourceFile(.{ .file = b.path("src/platform/stb_shim.c"), .flags = &.{"-O2"} });
}
