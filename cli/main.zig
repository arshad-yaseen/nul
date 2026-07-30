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
    \\  tree <file>    print the syntax tree
    \\  check <file>   report what is wrong with the file
    \\
    \\options:
    \\  --color auto|on|off   colour the output (default: auto)
    \\  --version             print the version
    \\
;

const Command = enum { tree, check };

const ColorChoice = enum { auto, on, off };

/// What the command line asked for, once it has been read.
const Request = struct {
    command: Command,
    path: []const u8,
    color: ColorChoice,
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
    defer source.deinit(init.gpa);

    var tree = try compiler.AST.parse(init.gpa, source.bytes);
    defer tree.deinit(init.gpa);
    assert(tree.nodes.len > 0);

    if (tree.errors.len > 0) {
        const color = try resolve(request.color, init.io, std.Io.File.stderr());
        for (tree.errors) |diagnostic| {
            try diagnostic.render(init.gpa, &source, log, color);
        }
        return 1;
    }

    // a tree with errors is never walked by anything but the renderer
    switch (request.command) {
        .tree => try compiler.dump(tree, out),
        .check => {},
    }
    return 0;
}

const ArgsResult = union(enum) { ready: Request, done: u8 };

fn readArgs(args: []const [:0]const u8, out: *Writer, log: *Writer) !ArgsResult {
    assert(args.len > 0);
    assert(out != log);

    var command: ?Command = null;
    var path: ?[]const u8 = null;
    var color: ColorChoice = .auto;

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
