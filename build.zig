const std = @import("std");

const zon = @import("build.zig.zon");

const test_dirs = [_][]const u8{
    "test/parse-pass",
    "test/parse-error",
    "test/ir",
    "test/fail",
    "test/multi",
};

/// Analysis recurses once per nesting level, so every binary that runs it asks
/// for room for the deepest source the parser allows.
const analysis_stack_bytes = 256 << 20;

const release_targets = [_][]const u8{
    "aarch64-macos",
    "x86_64-macos",
    "aarch64-linux-musl",
    "x86_64-linux-musl",
    "x86_64-windows",
};

const release_docs = [_][]const u8{ "README.md", "LICENSE" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = resolveVersion(b);

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const compiler = b.addModule("compiler", .{
        .root_source_file = b.path("compiler/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zol",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zol/main.zig"),
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
    b.step("run", "Build and run zol").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests and file tests");

    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit.stack_size = analysis_stack_bytes;
    test_step.dependOn(&b.addRunArtifact(unit).step);

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

    const file_tests = b.addRunArtifact(runner);
    addTestFiles(b, file_tests);
    test_step.dependOn(&file_tests.step);

    const update = b.addRunArtifact(runner);
    update.addArg("--update");
    addTestFiles(b, update);
    b.step("test-update", "Rewrite what the file tests expect").dependOn(&update.step);

    addRelease(b, version, options);
}

/// One tree per target under `zig-out/release`, each holding the binary, the
/// standard library it reads, and the terms it ships under. Archiving is the
/// packaging step's job, so nothing here shells out.
fn addRelease(b: *std.Build, version: []const u8, options: *std.Build.Step.Options) void {
    const release_step = b.step("release", "Cross-compile a release tree for every target");

    for (release_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            std.debug.panic("release target '{s}' is not a target triple", .{triple});
        const exe = addZol(b, b.resolveTargetQuery(query), .ReleaseFast, options);

        const tree = b.fmt("release/zol-{s}-{s}", .{ version, triple });
        const binary = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{tree}) } },
        });
        release_step.dependOn(&binary.step);

        const library = b.addInstallDirectory(.{
            .source_dir = b.path("lib"),
            .install_dir = .{ .custom = tree },
            .install_subdir = "lib",
        });
        release_step.dependOn(&library.step);

        for (release_docs) |doc| {
            const copied = b.addInstallFile(b.path(doc), b.fmt("{s}/{s}", .{ tree, doc }));
            release_step.dependOn(&copied.step);
        }
    }
}

/// The binary, and the compiler module it is built over.
fn addZol(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const compiler = b.createModule(.{
        .root_source_file = b.path("compiler/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zol",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zol/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compiler", .module = compiler },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    exe.stack_size = analysis_stack_bytes;
    return exe;
}

/// The manifest carries the next, unreleased version. A build standing on the
/// matching tag is that release, and every other build says which commit it
/// came from, so a report names one revision rather than a branch.
fn resolveVersion(b: *std.Build) []const u8 {
    const manifest = zon.version;

    var code: u8 = undefined;
    const stdout = b.runAllowFail(&.{
        "git",                        "-C",
        b.build_root.path orelse ".", "describe",
        "--match",                    "*.*.*",
        "--tags",                     "--abbrev=9",
    }, &code, .ignore) catch return manifest;
    const described = std.mem.trim(u8, stdout, " \n\r");

    // no trailing distance means the commit carries the tag itself
    if (std.mem.indexOfScalar(u8, described, '-') == null) {
        if (std.mem.eql(u8, described, manifest)) return manifest;
        std.debug.panic(
            "tag '{s}' and build.zig.zon version '{s}' disagree",
            .{ described, manifest },
        );
    }

    // `0.1.0-47-g7f3a91c9a` is 47 commits past 0.1.0, so the next one is brewing
    var fields = std.mem.splitBackwardsScalar(u8, described, '-');
    const hash = fields.next() orelse return manifest;
    const distance = fields.next() orelse return manifest;
    return b.fmt("{s}-dev.{s}+{s}", .{ manifest, distance, hash[1..] });
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
            // a multi-module case is a directory entered at main.zol
            if (entry.kind == .directory) {
                const main_path = b.fmt("{s}/{s}/main.zol", .{ sub, entry.name });
                dir.access(io, b.fmt("{s}/main.zol", .{entry.name}), .{}) catch continue;
                names.append(b.allocator, main_path) catch @panic("OOM");
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zol")) continue;
            names.append(b.allocator, b.fmt("{s}/{s}", .{ sub, entry.name })) catch @panic("OOM");
        }
        std.mem.sort([]const u8, names.items, {}, stringLessThan);
        for (names.items) |name| run.addArg(name);
    }
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
