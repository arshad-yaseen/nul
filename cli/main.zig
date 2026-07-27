//! The `nul` command. Parses arguments, drives the compiler, and chooses an exit code.

const std = @import("std");
const Io = std.Io;

const compiler = @import("compiler");
const Compilation = compiler.Compilation;
const Diagnostic = compiler.Diagnostic;

const version = @import("build_options").version;

const Exit = enum(u8) { ok = 0, failed = 1, misused = 2 };

const usage =
    \\nul <command> [options]
    \\
    \\  check <file>   Check a file, reporting anything the compiler can prove wrong
    \\  version        Print the version
    \\  help           Print this message
    \\
    \\Options for check:
    \\  --color        Colour the output even when it is not a terminal
    \\  --no-color     Never colour the output
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return @intFromEnum(try run(init, args[1..], w));
}

fn run(init: std.process.Init, args: []const []const u8, w: *Io.Writer) !Exit {
    if (args.len == 0) {
        try w.writeAll(usage);
        return .misused;
    }
    const command = args[0];

    if (is(command, "check")) return check(init, args[1..], w);
    if (is(command, "version")) {
        try w.print("nul {s}\n", .{version});
        return .ok;
    }
    if (is(command, "help") or is(command, "-h") or is(command, "--help")) {
        try w.writeAll(usage);
        return .ok;
    }

    try w.print("nul: there is no '{s}' command\n", .{command});
    // A path where a command belongs is the likeliest slip, so name the fix.
    if (std.mem.endsWith(u8, command, ".nul")) {
        try w.print("did you mean 'nul check {s}'?\n", .{command});
    } else {
        try w.writeAll("run 'nul help' to see what there is\n");
    }
    return .misused;
}

fn check(init: std.process.Init, args: []const []const u8, w: *Io.Writer) !Exit {
    var color: ?bool = null;
    var path: ?[]const u8 = null;

    for (args) |arg| {
        if (is(arg, "--color")) {
            color = true;
        } else if (is(arg, "--no-color")) {
            color = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try w.print("nul check: there is no '{s}' option\n", .{arg});
            return .misused;
        } else if (path != null) {
            try w.writeAll("nul check: one file at a time, for now\n");
            return .misused;
        } else {
            path = arg;
        }
    }

    const file = path orelse {
        try w.writeAll("nul check: expected a file to check\n");
        return .misused;
    };

    const gpa = init.gpa;
    var result = Compilation.check(gpa, init.io, Io.Dir.cwd(), file) catch |e| {
        try w.print("nul: cannot read '{s}': {s}\n", .{ file, @errorName(e) });
        return .misused;
    };
    defer result.deinit(gpa);

    const count = result.errorCount();
    if (count == 0) return .ok;

    const tty = Io.File.stdout().isTty(init.io) catch false;
    try result.render(gpa, w, if (color orelse tty) .ansi else .plain);
    try w.print("\n{d} error{s} found\n", .{ count, if (count == 1) "" else "s" });
    return .failed;
}

fn is(arg: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, arg, name);
}
