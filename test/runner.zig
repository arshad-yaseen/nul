const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const compiler = @import("compiler");
const verify = @import("verify.zig");

const Kind = enum {
    /// Must parse.
    @"parse-pass",
    /// Must not parse.
    @"parse-error",
    /// Must compile clean.
    pass,
    /// Must be refused.
    fail,
    /// A directory of modules entered at `main.nul`.
    multi,
    /// Must emit C that a C compiler accepts.
    emit,
    /// Must compile and run, and leave the recorded exit code.
    run,

    fn extension(kind: Kind) []const u8 {
        return switch (kind) {
            .@"parse-pass" => ".tree",
            .@"parse-error", .fail, .multi => ".expected",
            .pass => ".ir",
            .emit => ".c",
            .run => ".exit",
        };
    }

    fn analyzes(kind: Kind) bool {
        return switch (kind) {
            .@"parse-pass", .@"parse-error" => false,
            .pass, .fail, .multi, .emit, .run => true,
        };
    }
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len > 0);

    var log_buffer: [4096]u8 = undefined;
    var log = std.Io.File.stderr().writer(init.io, &log_buffer);
    defer log.interface.flush() catch {};

    var update = false;
    var failures: u32 = 0;
    var ran: u32 = 0;

    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--update")) {
            update = true;
            continue;
        }

        ran += 1;
        const passed = try runOne(init.gpa, init.io, argument, update, &log.interface);
        if (passed == false) failures += 1;
    }

    assert(ran >= failures);
    if (failures > 0) {
        try log.interface.print("{d} of {d} file tests failed\n", .{ failures, ran });
        return 1;
    }
    return 0;
}

fn runOne(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    update: bool,
    log: *Writer,
) !bool {
    assert(path.len > ".nul".len);
    assert(std.mem.endsWith(u8, path, ".nul"));
    const kind = kindOf(path) orelse {
        try log.print("{s}: not under a directory the runner knows\n", .{path});
        return false;
    };

    var actual: Writer.Allocating = .init(gpa);
    defer actual.deinit();

    const produced = if (kind.analyzes())
        try runCompile(gpa, io, path, kind, &actual.writer, log)
    else
        try runParse(gpa, io, path, kind, &actual.writer, log);
    if (produced == false) return false;

    const golden_path = try std.fmt.allocPrint(gpa, "{s}{s}", .{
        path[0 .. path.len - ".nul".len],
        kind.extension(),
    });
    defer gpa.free(golden_path);

    if (update) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = actual.written() });
        return true;
    }

    const golden = std.Io.Dir.cwd().readFileAlloc(io, golden_path, gpa, .limited(1 << 22)) catch {
        try log.print("{s}: no golden yet, run 'zig build test-update'\n", .{golden_path});
        return false;
    };
    defer gpa.free(golden);

    if (std.mem.eql(u8, golden, actual.written())) return true;

    try log.print("{s}: does not match\n--- expected ---\n{s}--- actual ---\n{s}---\n", .{
        golden_path, golden, actual.written(),
    });
    return false;
}

/// Tokenize and parse only.
fn runParse(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    kind: Kind,
    actual: *Writer,
    log: *Writer,
) !bool {
    var source: compiler.Source = try .load(gpa, io, .cwd(), path);
    defer source.deinit(gpa);

    var tree = try compiler.AST.parse(gpa, source.bytes);
    defer tree.deinit(gpa);

    // the dump has to survive every tree, including one made mostly of holes
    var sink: Writer.Discarding = .init(&.{});
    try compiler.dump.tree(tree, &sink.writer);

    switch (kind) {
        .@"parse-pass" => {
            if (tree.errors.len > 0) {
                try log.print("{s}: expected to parse, but\n", .{path});
                for (tree.errors) |diagnostic| {
                    try diagnostic.render(gpa, &source, log, .off);
                }
                return false;
            }
            try compiler.dump.tree(tree, actual);
        },
        .@"parse-error" => {
            if (tree.errors.len == 0) {
                try log.print("{s}: expected a diagnostic, got none\n", .{path});
                return false;
            }
            for (tree.errors) |diagnostic| try diagnostic.render(gpa, &source, actual, .off);
        },
        else => unreachable,
    }
    return true;
}

/// The whole pipeline, against the repository's own `lib/std`.
fn runCompile(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    kind: Kind,
    actual: *Writer,
    log: *Writer,
) !bool {
    const source: compiler.Source = try .load(gpa, io, .cwd(), path);

    var comp: compiler.Compilation = undefined;
    try comp.init(gpa, io, .{ .root_path = path, .std_dir = "lib/std" });
    defer comp.deinit();
    try comp.compile(source);
    verify.all(&comp);

    const failed = comp.diagnostics.items.len > 0;
    switch (kind) {
        .pass => {
            if (failed) {
                try log.print("{s}: expected to compile, but\n", .{path});
                try comp.renderAll(log, .off);
                return false;
            }
            try comp.dumpIR(actual);
        },
        .fail => {
            if (failed == false) {
                try log.print("{s}: expected a diagnostic, got none\n", .{path});
                return false;
            }
            try comp.renderAll(actual, .off);
        },
        .multi => if (failed) {
            try comp.renderAll(actual, .off);
        } else {
            try comp.dumpIR(actual);
        },
        .emit, .run => {
            if (failed) {
                try log.print("{s}: expected to compile, but\n", .{path});
                try comp.renderAll(log, .off);
                return false;
            }
            if (kind == .emit) {
                _ = try compiler.EmitC.run(&comp, gpa, actual);
            } else {
                const code = try runCompiled(gpa, io, &comp, path, log) orelse return false;
                try actual.print("{d}\n", .{code});
            }
        },
        else => unreachable,
    }
    return true;
}

/// Emit, hand the C to a compiler, run the result, and report its exit code.
/// This is the only layer that tests what a program means rather than how it
/// is spelled.
fn runCompiled(
    gpa: Allocator,
    io: std.Io,
    comp: *const compiler.Compilation,
    path: []const u8,
    log: *Writer,
) !?u8 {
    var source: Writer.Allocating = .init(gpa);
    defer source.deinit();
    if (try compiler.EmitC.run(comp, gpa, &source.writer) == false) {
        try log.print("{s}: no 'main', so there is nothing to run\n", .{path});
        return null;
    }

    const stem = std.fs.path.stem(path);
    const c_path = try std.fmt.allocPrint(gpa, ".zig-cache/nul-{s}.c", .{stem});
    defer gpa.free(c_path);
    const exe_path = try std.fmt.allocPrint(gpa, ".zig-cache/nul-{s}.exe", .{stem});
    defer gpa.free(exe_path);

    const cwd: std.Io.Dir = .cwd();
    try cwd.writeFile(io, .{ .sub_path = c_path, .data = source.written() });
    defer cwd.deleteFile(io, c_path) catch {};

    const built = try std.process.run(gpa, io, .{ .argv = &.{
        "zig", "cc", "-std=c99", "-pedantic", "-O1", "-o", exe_path, c_path,
    } });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    defer cwd.deleteFile(io, exe_path) catch {};

    switch (built.term) {
        .exited => |code| if (code != 0) {
            try log.print("{s}: the C compiler refused it\n{s}", .{ path, built.stderr });
            return null;
        },
        else => {
            try log.print("{s}: the C compiler did not finish\n", .{path});
            return null;
        },
    }

    const ran = try std.process.run(gpa, io, .{ .argv = &.{exe_path} });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    return switch (ran.term) {
        .exited => |code| code,
        else => {
            try log.print("{s}: the program did not exit normally\n", .{path});
            return null;
        },
    };
}

/// The kind is the path component after `test/`.
fn kindOf(path: []const u8) ?Kind {
    assert(path.len > 0);
    if (std.mem.endsWith(u8, path, ".nul") == false) return null;

    var components = std.mem.splitScalar(u8, path, '/');
    const first = components.next() orelse return null;
    if (std.mem.eql(u8, first, "test") == false) return null;
    const second = components.next() orelse return null;
    return std.meta.stringToEnum(Kind, second);
}
