const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nul",
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run").dependOn(&run.step);

    // Unit tests. Each root is a file whose `test` blocks should run; a file only
    // contributes tests when something imports it, so new roots go here.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{"compiler/Type.zig"}) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
