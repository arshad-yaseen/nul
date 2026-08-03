const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

const build_options = @import("build_options");
const compiler = @import("compiler");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len > 0);

    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);

    var log_buffer: [4096]u8 = undefined;
    var log = std.Io.File.stderr().writer(init.io, &log_buffer);

    const status = run(init, args, &out.interface, &log.interface) catch |err| status: {
        try log.interface.print("nul: {t}\n", .{err});
        break :status 2;
    };

    try out.interface.flush();
    try log.interface.flush();
    return status;
}

const usage =
    \\usage: nul <command> <entry>
    \\
    \\An entry is one file. Everything it imports is part of the program.
    \\
    \\commands:
    \\  run <entry>   check, compile, and run the program
    \\  ir  <entry>   print the typed IR
    \\
    \\options:
    \\  --cc <program>        the C compiler to run (default: zig cc)
    \\  --std <dir>           where the standard library lives
    \\  --color auto|on|off   colour the output (default: auto)
    \\  --version             print the version
    \\
;

const Command = enum { run, ir };

const ColorChoice = enum { auto, on, off };

const Request = struct {
    command: Command,
    path: []const u8,
    color: ColorChoice,
    std_dir: ?[]const u8,
    compiler: []const u8,
};

fn run(init: std.process.Init, args: []const [:0]const u8, out: *Writer, log: *Writer) !u8 {
    const request = switch (try readArgs(args, out, log)) {
        .ready => |request| request,
        .done => |status| return status,
    };

    // monotonic, so a clock the operator resets cannot make a phase negative
    const started = std.Io.Clock.awake.now(init.io);

    const source: compiler.Source = compiler.Source.load(
        init.gpa,
        init.io,
        .cwd(),
        request.path,
    ) catch |err| switch (err) {
        error.ReadFailed => {
            try log.print("nul: cannot read '{s}'\n", .{request.path});
            return 2;
        },
        error.SourceTooLarge => {
            try log.print("nul: '{s}' is larger than the compiler can index\n", .{request.path});
            return 2;
        },
        error.OutOfMemory => return err,
    };

    var comp: compiler.Compilation = undefined;
    try comp.init(init.gpa, init.io, .{
        .root_path = request.path,
        .std_dir = request.std_dir orelse try findStd(init),
    });
    defer comp.deinit();

    // the compilation owns the root source from here
    try comp.compile(source);

    if (comp.diagnostics.items.len > 0) {
        const color: compiler.Diagnostic.Color = switch (request.color) {
            .on => .on,
            .off => .off,
            .auto => if (try std.Io.File.stderr().isTty(init.io)) .on else .off,
        };
        try comp.renderAll(log, color);
        return 1;
    }

    if (request.command == .ir) {
        try comp.dumpIR(out);
        return 0;
    }
    return runProgram(init, &comp, request, out, log, started);
}

/// Emit C, hand it to a C compiler, run the result, and report its exit code.
fn runProgram(
    init: std.process.Init,
    comp: *const compiler.Compilation,
    request: Request,
    out: *Writer,
    log: *Writer,
    started: std.Io.Timestamp,
) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const cwd: std.Io.Dir = .cwd();

    var emitted: Writer.Allocating = .init(gpa);
    defer emitted.deinit();

    const has_entry = compiler.EmitC.run(comp, gpa, &emitted.writer) catch |err| switch (err) {
        error.ArenaUnsupported => {
            try log.print("nul: the C backend does not support arenas yet\n", .{});
            return 2;
        },
        else => return err,
    };
    if (has_entry == false) {
        try log.print("nul: '{s}' has no 'main', so there is nothing to run\n", .{request.path});
        return 2;
    }
    const checked = started.durationTo(std.Io.Clock.awake.now(init.io));

    const stem = std.fs.path.stem(request.path);
    const c_path = try std.fmt.allocPrint(arena, "./.nul-{s}.c", .{stem});
    const exe_path = try std.fmt.allocPrint(arena, "./.nul-{s}", .{stem});
    try cwd.writeFile(init.io, .{ .sub_path = c_path, .data = emitted.written() });
    defer cwd.deleteFile(init.io, c_path) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, request.compiler);
    // the default is the toolchain's own clang, which every install already has
    if (std.mem.eql(u8, request.compiler, "zig")) try argv.append(gpa, "cc");
    try argv.appendSlice(gpa, &.{ "-std=c99", "-pedantic", "-O2", "-o", exe_path, c_path });

    const compiling = std.Io.Clock.awake.now(init.io);
    const built = std.process.run(gpa, init.io, .{ .argv = argv.items }) catch |err| {
        try log.print("nul: cannot run '{s}': {t}\n", .{ request.compiler, err });
        return 2;
    };
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);

    const refused = switch (built.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (refused) {
        try log.print("nul: the C compiler refused the emitted C\n{s}", .{built.stderr});
        return 2;
    }
    const compiled = compiling.durationTo(std.Io.Clock.awake.now(init.io));
    defer cwd.deleteFile(init.io, exe_path) catch {};

    const running = std.Io.Clock.awake.now(init.io);
    const ran = try std.process.run(gpa, init.io, .{ .argv = &.{exe_path} });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    const elapsed = running.durationTo(std.Io.Clock.awake.now(init.io));

    try log.print("nul: checked in {f}, {s} in {f}, ran in {f}\n", .{
        checked, label(request.compiler), compiled, elapsed,
    });
    try out.writeAll(ran.stdout);

    // a program speaks through its exit code, which is what a shell would show
    return switch (ran.term) {
        .exited => |code| {
            try out.print("{d}\n", .{code});
            return 0;
        },
        else => {
            try log.print("nul: the program did not exit normally\n", .{});
            return 2;
        },
    };
}

fn label(compiler_name: []const u8) []const u8 {
    if (std.mem.eql(u8, compiler_name, "zig")) return "zig cc";
    return compiler_name;
}

/// Beside the binary as `../lib/std`, or `lib/std` under the working directory.
fn findStd(init: std.process.Init) !?[]const u8 {
    const arena = init.arena.allocator();

    if (std.process.executablePathAlloc(init.io, arena)) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            const beside = try std.fs.path.join(arena, &.{ exe_dir, "..", "lib", "std" });
            if (dirExists(init.io, beside)) return beside;
        }
    } else |_| {}

    if (dirExists(init.io, "lib/std")) return "lib/std";
    return null;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    assert(path.len > 0);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

const ArgsResult = union(enum) { ready: Request, done: u8 };

fn readArgs(args: []const [:0]const u8, out: *Writer, log: *Writer) !ArgsResult {
    assert(args.len > 0);
    assert(out != log);

    var command: ?Command = null;
    var path: ?[]const u8 = null;
    var color: ColorChoice = .auto;
    var std_dir: ?[]const u8 = null;
    var compiler_name: []const u8 = "zig";

    var index: u32 = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];

        if (std.mem.eql(u8, argument, "--version")) {
            try out.print("{s}\n", .{build_options.version});
            return .{ .done = 0 };
        }

        if (std.mem.eql(u8, argument, "--color")) {
            index += 1;
            if (index == args.len) return .{ .done = try misuse(log, "--color needs a setting") };
            color = std.meta.stringToEnum(ColorChoice, args[index]) orelse {
                return .{ .done = try misuse(log, "--color takes auto, on, or off") };
            };
            continue;
        }

        if (std.mem.eql(u8, argument, "--cc")) {
            index += 1;
            if (index == args.len) return .{ .done = try misuse(log, "--cc needs a program") };
            compiler_name = args[index];
            continue;
        }

        if (std.mem.eql(u8, argument, "--std")) {
            index += 1;
            if (index == args.len) return .{ .done = try misuse(log, "--std needs a directory") };
            std_dir = args[index];
            continue;
        }

        if (command == null) {
            command = std.meta.stringToEnum(Command, argument) orelse {
                return .{ .done = try misuse(log, "no such command") };
            };
        } else {
            if (path != null) return .{ .done = try misuse(log, "one entry at a time") };
            path = argument;
        }
    }

    return .{ .ready = .{
        .command = command orelse return .{ .done = try misuse(log, "no command given") },
        .path = path orelse return .{ .done = try misuse(log, "no entry given") },
        .color = color,
        .std_dir = std_dir,
        .compiler = compiler_name,
    } };
}

fn misuse(log: *Writer, problem: []const u8) Writer.Error!u8 {
    assert(problem.len > 0);
    try log.print("nul: {s}\n\n{s}", .{ problem, usage });
    return 2;
}
