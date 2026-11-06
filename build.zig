const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });

    for ([_][]const u8{ "latency", "kfxstat" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
                .target = target,
                .optimize = .ReleaseFast,
                .strip = true,
            }),
        });
        b.installArtifact(exe);
    }

    for ([_][]const u8{ "pagetest", "reader" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
                .target = target,
                .optimize = .ReleaseFast,
                .strip = true,
                .link_libc = true,
            }),
        });
        exe.root_module.addIncludePath(b.path("third_party"));
        exe.root_module.addCSourceFile(.{ .file = b.path("src/stb_shim.c"), .flags = &.{"-O2"} });
        b.installArtifact(exe);
    }

    const test_step = b.step("test", "Run unit tests on the host");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ion.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
