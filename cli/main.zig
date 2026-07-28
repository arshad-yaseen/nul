//! The `nul` command. Parses arguments, drives the compiler, and chooses an exit code.
//! Diagnostics go to stderr; what the command produces goes to stdout.

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
    \\  build <file>   Check a file, then write the C it compiles to
    \\  version        Print the version
    \\  help           Print this message
    \\
    \\Options:
    \\  -o <file>      Where build writes its C, or '-' for standard output
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
    if (is(command, "build")) return compile(init, args[1..], out, err, .build);
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

const Mode = enum { check, build };

fn compile(
    init: std.process.Init,
    args: []const []const u8,
    out: *Io.Writer,
    err: *Io.Writer,
    mode: Mode,
) !Exit {
    const name = @tagName(mode);
    var color: ?bool = null;
    var emit_path: ?[]const u8 = null;
    var path: ?[]const u8 = null;

    var at: usize = 0;
    while (at < args.len) : (at += 1) {
        const arg = args[at];
        if (is(arg, "--color")) {
            color = true;
        } else if (is(arg, "--no-color")) {
            color = false;
        } else if (is(arg, "-o")) {
            at += 1;
            if (at == args.len) {
                try err.print("nul {s}: -o wants a file after it\n", .{name});
                return .misused;
            }
            emit_path = args[at];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try err.print("nul {s}: there is no '{s}' option\n", .{ name, arg });
            return .misused;
        } else if (path != null) {
            try err.writeAll("nul: one file at a time, for now\n");
            return .misused;
        } else {
            path = arg;
        }
    }

    const file = path orelse {
        try err.print("nul {s}: expected a file\n", .{name});
        return .misused;
    };
    if (mode == .check and emit_path != null) {
        try err.writeAll("nul check: -o belongs to build, which is the one that writes C\n");
        return .misused;
    }

    const gpa = init.gpa;
    const cwd = Io.Dir.cwd();

    // C accumulates in memory so a rejected program never reaches the disk.
    var c: Io.Writer.Allocating = .init(gpa);
    defer c.deinit();
    const emit: ?*Io.Writer = if (mode == .build) &c.writer else null;

    var result = Compilation.build(gpa, init.io, cwd, file, emit) catch |e| {
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
    if (mode == .check) return .ok;

    const target = emit_path orelse try cPath(init.arena.allocator(), file);
    if (is(target, "-")) {
        try out.writeAll(c.written());
        return .ok;
    }
    writeFile(init.io, cwd, target, c.written()) catch |e| {
        try err.print("nul: cannot write '{s}': {s}\n", .{ target, @errorName(e) });
        return .misused;
    };
    try out.print("{s}\n", .{target});
    return .ok;
}

/// `hello.nul` becomes `hello.c`, next to where it came from.
fn cPath(arena: std.mem.Allocator, file: []const u8) ![]const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, file, '.')) |dot| file[0..dot] else file;
    return std.fmt.allocPrint(arena, "{s}.c", .{stem});
}

fn writeFile(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn is(arg: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, arg, name);
}
