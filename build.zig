const std = @import("std");

const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const compiler = b.addModule("compiler", .{
        .root_source_file = b.path("compiler/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "nul",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compiler", .module = compiler },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run nul").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests and file tests");
    for ([_][]const u8{ "compiler/Value.zig", "compiler/Diagnostic.zig" }) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const runner = b.addExecutable(.{
        .name = "filetest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "compiler", .module = compiler }},
        }),
    });

    const file_tests = b.addRunArtifact(runner);
    addTestFiles(b, file_tests);
    test_step.dependOn(&file_tests.step);

    const update = b.addRunArtifact(runner);
    update.addArg("--update");
    addTestFiles(b, update);
    b.step("test-update", "Rewrite what the file tests expect").dependOn(&update.step);
}

fn addTestFiles(b: *std.Build, run: *std.Build.Step.Run) void {
    run.setCwd(b.path("."));
    const io = b.graph.io;
    for ([_][]const u8{ "test/pass", "test/fail" }) |sub| {
        var dir = b.build_root.handle.openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var names: std.ArrayList([]const u8) = .empty;
        var walk = dir.iterate();
        while (walk.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".nul")) continue;
            names.append(b.allocator, b.fmt("{s}/{s}", .{ sub, entry.name })) catch @panic("OOM");
        }
        std.mem.sort([]const u8, names.items, {}, stringLessThan);
        for (names.items) |name| run.addArg(name);
    }
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
