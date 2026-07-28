//! The `nul` command. Parses arguments, drives the compiler, and chooses an exit code.
//! Diagnostics go to stderr, and what the command produces goes to stdout.

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
    \\  dump <file>    Print the IR a file lowers to
    \\  version        Print the version
    \\  help           Print this message
    \\
    \\Options:
    \\  --color        Colour the output even when it is not a terminal
    \\  --no-color     Never colour the output
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &out_buf);
    var stderr = Io.File.stderr().writer(init.io, &err_buf);
    const out = &stdout.interface;
    const err = &stderr.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return @intFromEnum(try run(init, args[1..], out, err));
}

fn run(init: std.process.Init, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !Exit {
    if (args.len == 0) {
        try err.writeAll(usage);
        return .misused;
    }
    const command = args[0];

    if (is(command, "check")) return compile(init, args[1..], out, err, .check);
    if (is(command, "dump")) return compile(init, args[1..], out, err, .dump);
    if (is(command, "version")) {
        try out.print("nul {s}\n", .{version});
        return .ok;
    }
    if (is(command, "help") or is(command, "-h") or is(command, "--help")) {
        try out.writeAll(usage);
        return .ok;
    }

    try err.print("nul: there is no '{s}' command\n", .{command});
    // A path where a command belongs is the likeliest slip, so name the fix.
    if (std.mem.endsWith(u8, command, ".nul")) {
        try err.print("did you mean 'nul check {s}'?\n", .{command});
    } else {
        try err.writeAll("run 'nul help' to see what there is\n");
    }
    return .misused;
}

const Mode = enum { check, dump };

fn compile(
    init: std.process.Init,
    args: []const []const u8,
    out: *Io.Writer,
    err: *Io.Writer,
    mode: Mode,
) !Exit {
    var color: ?bool = null;
    var path: ?[]const u8 = null;

    for (args) |arg| {
        if (is(arg, "--color")) {
            color = true;
        } else if (is(arg, "--no-color")) {
            color = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try err.print("nul {s}: there is no '{s}' option\n", .{ @tagName(mode), arg });
            return .misused;
        } else if (path != null) {
            try err.writeAll("nul: one file at a time, for now\n");
            return .misused;
        } else {
            path = arg;
        }
    }
    const file = path orelse {
        try err.print("nul {s}: expected a file\n", .{@tagName(mode)});
        return .misused;
    };

    const gpa = init.gpa;
    const cwd = Io.Dir.cwd();

    var result = switch (mode) {
        .check => Compilation.check(gpa, init.io, cwd, file),
        .dump => Compilation.dump(gpa, init.io, cwd, file, out),
    } catch |e| {
        try err.print("nul: cannot read '{s}': {s}\n", .{ file, @errorName(e) });
        return .misused;
    };
    defer result.deinit(gpa);

    const count = result.errorCount();
    if (count > 0) {
        const tty = Io.File.stderr().isTty(init.io) catch false;
        try result.render(gpa, err, if (color orelse tty) .ansi else .plain);
        try err.print("\n{d} error{s} found\n", .{ count, if (count == 1) "" else "s" });
        return .failed;
    }
    return .ok;
}

fn is(arg: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, arg, name);
}
