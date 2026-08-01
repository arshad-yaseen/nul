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
    \\  check <entry>   report the type and memory mistakes in the program
    \\  tree  <entry>   print one file's syntax tree
    \\  ir    <entry>   print the typed IR
    \\  c     <entry>   write the program as C
    \\  build <entry>   compile the program to an executable
    \\
    \\options:
    \\  -o <path>             where to write the output
    \\  --cc <program>        the C compiler to run (default: zig cc)
    \\  --std <dir>           where the standard library lives
    \\  --color auto|on|off   colour the output (default: auto)
    \\  --version             print the version
    \\
;

const Command = enum { tree, check, ir, c, build };

const ColorChoice = enum { auto, on, off };

const Request = struct {
    command: Command,
    path: []const u8,
    color: ColorChoice,
    std_dir: ?[]const u8,
    /// Standard output when the command writes C and nothing was asked for.
    output: ?[]const u8,
    compiler: []const u8,
};

fn run(init: std.process.Init, args: []const [:0]const u8, out: *Writer, log: *Writer) !u8 {
    assert(args.len > 0);

    const request = switch (try readArgs(args, out, log)) {
        .ready => |request| request,
        .done => |status| return status,
    };

    var source: compiler.Source = compiler.Source.load(
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

    if (request.command == .tree) {
        defer source.deinit(init.gpa);
        return runTree(init, &source, out, log, request.color);
    }

    var comp: compiler.Compilation = undefined;
    try comp.init(init.gpa, init.io, .{
        .root_path = request.path,
        .std_dir = request.std_dir orelse try findStd(init),
    });
    defer comp.deinit();

    // the compilation owns the root source from here
    try comp.compile(source);

    if (comp.diagnostics.items.len > 0) {
        const color = try resolve(request.color, init.io, std.Io.File.stderr());
        try comp.renderAll(log, color);
        return 1;
    }

    switch (request.command) {
        .check => {},
        .ir => try comp.dumpIR(out),
        .c, .build => return runBackend(init, &comp, request, out, log),
        .tree => unreachable,
    }
    return 0;
}

fn runBackend(
    init: std.process.Init,
    comp: *const compiler.Compilation,
    request: Request,
    out: *Writer,
    log: *Writer,
) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var source: Writer.Allocating = .init(gpa);
    defer source.deinit();

    compiler.EmitC.run(comp, gpa, &source.writer) catch |err| switch (err) {
        error.ArenaUnsupported => {
            try log.print("nul: the C backend does not support arenas yet\n", .{});
            return 2;
        },
        else => return err,
    };

    if (request.command == .c) {
        const path = request.output orelse {
            try out.writeAll(source.written());
            return 0;
        };
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = source.written() });
        return 0;
    }

    const exe = request.output orelse "a.out";
    const c_path = try std.fmt.allocPrint(arena, "{s}.c", .{exe});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = c_path, .data = source.written() });
    errdefer std.Io.Dir.cwd().deleteFile(init.io, c_path) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, request.compiler);
    // the default is the toolchain's own clang, which every install already has
    if (std.mem.eql(u8, request.compiler, "zig")) try argv.append(gpa, "cc");
    try argv.appendSlice(gpa, &.{ "-std=c99", "-pedantic", "-O2", "-o", exe, c_path });

    const result = std.process.run(gpa, init.io, .{ .argv = argv.items }) catch |err| {
        std.Io.Dir.cwd().deleteFile(init.io, c_path) catch {};
        try log.print("nul: cannot run '{s}': {t}\n", .{ request.compiler, err });
        return 2;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        try log.print("nul: the C compiler refused '{s}', which is left in place\n{s}", .{
            c_path, result.stderr,
        });
        return 2;
    }

    try std.Io.Dir.cwd().deleteFile(init.io, c_path);
    return 0;
}

fn runTree(
    init: std.process.Init,
    source: *compiler.Source,
    out: *Writer,
    log: *Writer,
    color_choice: ColorChoice,
) !u8 {
    var tree = try compiler.AST.parse(init.gpa, source.bytes);
    defer tree.deinit(init.gpa);
    assert(tree.nodes.len > 0);

    if (tree.errors.len > 0) {
        const color = try resolve(color_choice, init.io, std.Io.File.stderr());
        for (tree.errors) |diagnostic| {
            try diagnostic.render(init.gpa, source, log, color);
        }
        return 1;
    }
    try compiler.dump.tree(tree, out);
    return 0;
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
    var output: ?[]const u8 = null;
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

        if (std.mem.eql(u8, argument, "-o")) {
            index += 1;
            if (index == args.len) return .{ .done = try misuse(log, "-o needs a path") };
            output = args[index];
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
        .output = output,
        .compiler = compiler_name,
    } };
}

fn misuse(log: *Writer, problem: []const u8) Writer.Error!u8 {
    assert(problem.len > 0);
    try log.print("nul: {s}\n\n{s}", .{ problem, usage });
    return 2;
}

fn resolve(choice: ColorChoice, io: std.Io, file: std.Io.File) !compiler.Diagnostic.Color {
    assert(choice == .auto or choice == .on or choice == .off);
    return switch (choice) {
        .on => .on,
        .off => .off,
        .auto => if (try file.isTty(io)) .on else .off,
    };
}
