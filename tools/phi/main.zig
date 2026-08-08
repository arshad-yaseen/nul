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
        try log.interface.print("phi: {t}\n", .{err});
        break :status 2;
    };

    try out.interface.flush();
    try log.interface.flush();
    return status;
}

const usage =
    \\usage: phi <command> <entry>
    \\
    \\An entry is one file. Everything it imports is part of the program.
    \\
    \\commands:
    \\  check <entry>   check the program and report what is wrong
    \\  ir    <entry>   print the typed IR
    \\
    \\options:
    \\  --std <dir>           where the standard library lives
    \\  --color auto|on|off   colour the output (default: auto)
    \\  --version             print the version
    \\
;

const Command = enum { check, ir };

const ColorChoice = enum { auto, on, off };

const Request = struct {
    command: Command,
    path: []const u8,
    color: ColorChoice,
    std_dir: ?[]const u8,
};

// monotonic, so a machine that suspends mid-check cannot report a time that never elapsed
const clock: std.Io.Clock = .awake;

fn run(init: std.process.Init, args: []const [:0]const u8, out: *Writer, log: *Writer) !u8 {
    const request = switch (try readArgs(args, out, log)) {
        .ready => |request| request,
        .done => |status| return status,
    };

    // reading the entry is part of what the command costs, so the clock starts here
    const start = clock.now(init.io);

    const source: compiler.Source = compiler.Source.load(
        init.gpa,
        init.io,
        .cwd(),
        request.path,
    ) catch |err| switch (err) {
        error.ReadFailed => {
            try log.print("phi: cannot read '{s}'\n", .{request.path});
            return 2;
        },
        error.SourceTooLarge => {
            try log.print("phi: '{s}' is larger than the compiler can index\n", .{request.path});
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

    const elapsed = start.untilNow(init.io, clock);
    assert(elapsed.nanoseconds >= 0);

    const clean = comp.hasErrors() == false;
    if (clean) {
        if (request.command == .ir) try comp.dumpIR(out);
    } else {
        const color: compiler.Diagnostic.Color = switch (request.color) {
            .on => .on,
            .off => .off,
            .auto => if (try std.Io.File.stderr().isTty(init.io)) .on else .off,
        };
        try comp.renderAll(log, color);
    }

    try log.print("checked in {f}\n", .{elapsed});
    return if (clean) 0 else 1;
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
            if (path != null) return .{ .done = try misuse(log, "one entry at a time") };
            path = argument;
        }
    }

    return .{ .ready = .{
        .command = command orelse return .{ .done = try misuse(log, "no command given") },
        .path = path orelse return .{ .done = try misuse(log, "no entry given") },
        .color = color,
        .std_dir = std_dir,
    } };
}

fn misuse(log: *Writer, problem: []const u8) Writer.Error!u8 {
    assert(problem.len > 0);
    try log.print("phi: {s}\n\n{s}", .{ problem, usage });
    return 2;
}
