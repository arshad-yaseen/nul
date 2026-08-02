const std = @import("std");

const zon = @import("build.zig.zon");

const test_dirs = [_][]const u8{
    "test/parse-pass",
    "test/parse-error",
    "test/pass",
    "test/fail",
    "test/multi",
    "test/emit",
    "test/run",
};

const unit_test_roots = [_][]const u8{
    "compiler/root.zig",
};

/// Analysis recurses once per nesting level and nothing bounds the total, so
/// every binary that runs it asks for room for the deepest source the parser
/// and `Compilation.analyze_max` between them allow.
const analysis_stack_bytes = 256 << 20;

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
    exe.stack_size = analysis_stack_bytes;
    b.installArtifact(exe);

    // the standard library ships as source beside the binary
    b.installDirectory(.{
        .source_dir = b.path("lib"),
        .install_dir = .prefix,
        .install_subdir = "lib",
    });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run nul").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests and file tests");
    for (unit_test_roots) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.stack_size = analysis_stack_bytes;
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
    runner.stack_size = analysis_stack_bytes;

    const fuzzer = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "compiler", .module = compiler }},
        }),
    });
    fuzzer.stack_size = analysis_stack_bytes;

    const fuzz_short = b.addRunArtifact(fuzzer);
    fuzz_short.setCwd(b.path("."));
    fuzz_short.addArgs(&.{ "--iterations", "512" });
    test_step.dependOn(&fuzz_short.step);

    const fuzz_long = b.addRunArtifact(fuzzer);
    fuzz_long.setCwd(b.path("."));
    if (b.args) |args| fuzz_long.addArgs(args);
    b.step("fuzz", "Compile random programs, looking for a panic").dependOn(&fuzz_long.step);

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
    for (test_dirs) |sub| {
        var dir = b.build_root.handle.openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var names: std.ArrayList([]const u8) = .empty;
        var walk = dir.iterate();
        while (walk.next(io) catch null) |entry| {
            // a multi-module case is a directory whose entry file is main.nul
            if (entry.kind == .directory) {
                const main_path = b.fmt("{s}/{s}/main.nul", .{ sub, entry.name });
                dir.access(io, b.fmt("{s}/main.nul", .{entry.name}), .{}) catch continue;
                names.append(b.allocator, main_path) catch @panic("OOM");
                continue;
            }
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
