const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });

    // The app, with Zig's own bounds and overflow checks on: they cost page turns
    // nothing measurable. `-Dfast=true` builds without them.
    const fast = b.option(bool, "fast", "Build the app without Zig's runtime safety checks") orelse false;
    const noface = b.addExecutable(.{
        .name = "noface",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = if (fast) .ReleaseFast else .ReleaseSafe,
            .strip = true,
            .link_libc = true,
        }),
    });
    addFontAndImageCode(b, noface.root_module);
    b.installArtifact(noface);

    // The picture helper. Built against the Kindle's own glibc, because it loads the
    // Kindle's JPEG XR decoder at run time, which a static musl program can't.
    const jxr = b.addExecutable(.{
        .name = "jxr2pgm",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .arm,
                .os_tag = .linux,
                .abi = .gnueabihf,
                .glibc_version = .{ .major = 2, .minor = 35, .patch = 0 },
                .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
            }),
            .optimize = .ReleaseFast,
            .strip = true,
            .link_libc = true,
        }),
    });
    jxr.root_module.addCSourceFile(.{ .file = b.path("device/jxr/jxr2pgm.c"), .flags = &.{"-O2"} });
    b.installArtifact(jxr);

    // Ownership boundaries: `zig build check` fails when a file imports across one.
    const host = b.graph.host;
    const boundaries = b.addExecutable(.{
        .name = "boundaries",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/check/boundaries.zig"), .target = host }),
    });
    const run_boundaries = b.addRunArtifact(boundaries);
    run_boundaries.addArg("src");
    const check_step = b.step("check", "Check that files only import what their folder may use");
    check_step.dependOn(&run_boundaries.step);
    const boundary_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/check/boundaries.zig"), .target = host }) });
    check_step.dependOn(&b.addRunArtifact(boundary_tests).step);

    // Development tools, kept out of the app. Built with `zig build tools`.
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    addFontAndImageCode(b, core);

    const tools_step = b.step("tools", "Build the development tools in tools/");
    for ([_][]const u8{ "latency", "kfxstat", "pagetest", "panelshot", "touchsim", "fbcap", "fbrec", "kfxshape" }) |name| {
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
    module.addCSourceFile(.{ .file = b.path("src/gfx/stb_shim.c"), .flags = &.{"-O2"} });
}
