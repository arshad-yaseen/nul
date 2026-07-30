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
    \\usage: nul <command> <file>
    \\
    \\commands:
    \\  check <file>   report what is wrong with the file
    \\  tree <file>    print the syntax tree
    \\  ir <file>      print the typed IR
    \\
    \\options:
    \\  --std <dir>           where the standard library lives
    \\  --color auto|on|off   colour the output (default: auto)
    \\  --version             print the version
    \\
;

const Command = enum { tree, check, ir };

const ColorChoice = enum { auto, on, off };

/// What the command line asked for, once it has been read.
const Request = struct {
    command: Command,
    path: []const u8,
    color: ColorChoice,
    std_dir: ?[]const u8,
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
        .tree => unreachable,
    }
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
    try compiler.dump(tree, out);
    return 0;
}

/// Where the standard library is. Beside the binary as `../lib/std`, or a
/// `lib/std` under the working directory for work inside the repository.
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
            if (path != null) return .{ .done = try misuse(log, "one file at a time") };
            path = argument;
        }
    }

    return .{ .ready = .{
        .command = command orelse return .{ .done = try misuse(log, "no command given") },
        .path = path orelse return .{ .done = try misuse(log, "no file given") },
        .color = color,
        .std_dir = std_dir,
    } };
}

fn misuse(log: *Writer, problem: []const u8) Writer.Error!u8 {
    assert(problem.len > 0);
    try log.print("nul: {s}\n\n{s}", .{ problem, usage });
    return 2;
}

/// `auto` means colour when the stream is a terminal and plain when it is not.
fn resolve(choice: ColorChoice, io: std.Io, file: std.Io.File) !compiler.Diagnostic.Color {
    assert(choice == .auto or choice == .on or choice == .off);
    return switch (choice) {
        .on => .on,
        .off => .off,
        .auto => if (try file.isTty(io)) .on else .off,
    };
}
