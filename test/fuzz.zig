//! Random programs, checked for one property.
//!
//! > For any input, the compiler reports diagnostics or produces working
//! > output, and never panics.
//!
//! It knows nothing about what any construct means, which is why it finds the
//! interactions nobody predicted. A failure is a panic, so the run stops where
//! it broke, and `--trace` names the program to reproduce.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const compiler = @import("compiler");
const verify = @import("verify.zig");

const statements_max = 5;
const source_bytes_max = 8192;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len > 0);

    var log_buffer: [4096]u8 = undefined;
    var log = std.Io.File.stderr().writer(init.io, &log_buffer);
    defer log.interface.flush() catch {};

    var options: Options = .{ .iterations = 512, .seed = 0, .start = 0, .trace = false };
    try options.read(args[1..], &log.interface);

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(init.gpa);
    try source.ensureTotalCapacity(init.gpa, source_bytes_max);

    var clean: u32 = 0;
    var rejected: u32 = 0;
    var at: u32 = options.start;
    while (at < options.start + options.iterations) : (at += 1) {
        // one seed per program, so any one reproduces on its own
        var random: std.Random.DefaultPrng = .init(options.seed +% at);
        try generate(init.gpa, &source, random.random());

        if (options.trace) {
            try log.interface.print("{d}\n", .{at});
            try log.interface.flush();
        }

        if (try compileOne(init.gpa, init.io, source.items)) clean += 1 else rejected += 1;
    }

    try log.interface.print(
        "fuzz: {d} programs from seed {d}, {d} compiled, {d} refused, 0 panics\n",
        .{ options.iterations, options.seed, clean, rejected },
    );
    return 0;
}

const Options = struct {
    iterations: u32,
    seed: u64,
    start: u32,
    trace: bool,

    fn read(options: *Options, args: []const [:0]const u8, log: *Writer) !void {
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const name = args[index];
            if (std.mem.eql(u8, name, "--trace")) {
                options.trace = true;
                continue;
            }
            index += 1;
            if (index == args.len) {
                try log.print("fuzz: '{s}' needs a value\n", .{name});
                return error.BadArgument;
            }
            const value = args[index];
            if (std.mem.eql(u8, name, "--iterations")) {
                options.iterations = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--seed")) {
                options.seed = try std.fmt.parseInt(u64, value, 10);
            } else if (std.mem.eql(u8, name, "--start")) {
                options.start = try std.fmt.parseInt(u32, value, 10);
            } else {
                try log.print("fuzz: unknown option '{s}'\n", .{name});
                return error.BadArgument;
            }
        }
    }
};

fn compileOne(gpa: Allocator, io: std.Io, text: []const u8) !bool {
    const buffer = try gpa.alloc(u8, text.len + compiler.Source.padding);
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    const source: compiler.Source = .{ .path = "fuzz.nul", .bytes = buffer[0..text.len :0] };

    var comp: compiler.Compilation = undefined;
    try comp.init(gpa, io, .{ .root_path = "fuzz.nul", .std_dir = "lib/std" });
    defer comp.deinit();

    try comp.compile(source);
    verify.all(&comp);
    if (comp.diagnostics.items.len > 0) {
        // a diagnostic that cannot be printed is a failure too
        var sink: Writer.Discarding = .init(&.{});
        try comp.renderAll(&sink.writer, .off);
        return false;
    }

    var out: Writer.Discarding = .init(&.{});
    _ = compiler.EmitC.run(&comp, gpa, &out.writer) catch |err| switch (err) {
        error.ArenaUnsupported => return true,
        else => return err,
    };
    return true;
}

const exprs = [_][]const u8{
    "a",                            "1",
    "true",                         "null",
    "opt",                          "may",
    "p",                            "(a)",
    "a + 1",                        "-a",
    "!c",                           "a == 1",
    "p.v",                          "opt orelse 0",
    "opt orelse return 0",          "opt orelse { return 0 }",
    "opt orelse break",             "opt orelse continue",
    "may catch 0",                  "may catch return 0",
    "may catch |e| 0",              "may catch {}",
    "try may",                      "if c { 1 } else { 2 }",
    "if c { a } else { return 0 }", "if c { return 1 } else { return 2 }",
    "if c { 1 }",                   "(return 1)",
    "(break)",                      "(continue)",
    "return 0",                     "break",
    "continue",                     "if opt |v| { v } else { 0 }",
    "g(a)",                         "g(if c { 1 } else { 2 })",
    "Pair.make(a)",                 "p.total()",
    "arena.create[Pair]()",         "arena.copy(a)",
    "Missing",                      "may catch |e| if e == TooRisky { 1 } else { 0 }",
    "if c { null } else { null }",  "a + (if c { return 1 } else { return 2 })",
};

/// `$E` is where an expression goes.
const stmts = [_][]const u8{
    "let x = $E",
    "let x: i64 = $E",
    "var x: i64 = $E",
    "_ = $E",
    "$E",
    "return $E",
    "return Missing",
    "if c { $E }",
    "if c { $E } else { $E }",
    "while c { $E }",
    "while { $E }",
    "defer $E",
    "x = $E",
    "if opt |v| { _ = v }",
    "while opt |v| { _ = v }",
    "var s = arena.child()",
    "s.reset()",
    "{ let y = $E  _ = y }",
};

const header =
    \\use std.mem.Arena
    \\
    \\error Missing
    \\pub error TooRisky
    \\
;

const preamble =
    \\struct Pair {
    \\    v: i64
    \\
    \\    fn make(v: i64) Pair {
    \\        return .{ v: v }
    \\    }
    \\
    \\    fn total(self: Pair) i64 {
    \\        return self.v
    \\    }
    \\}
    \\
    \\fn g(n: i64) i64 {
    \\    return n
    \\}
    \\
    \\fn drive(arena: Arena, a: i64, c: bool, opt: ?i64, may: !i64, p: Pair) i64 {
    \\    var x: i64 = 0
    \\
;

const epilogue =
    \\    return x
    \\}
    \\
    \\fn main() i64 {
    \\    return 0
    \\}
    \\
;

fn generate(gpa: Allocator, source: *std.ArrayList(u8), random: std.Random) !void {
    source.clearRetainingCapacity();
    try source.appendSlice(gpa, header);

    // a top-level binding is checked with no body to lower into, which is a
    // second mode the same expressions have to survive
    for (0..random.uintLessThan(u32, 3)) |at| {
        try source.print(gpa, "let k{d} = {s}\n", .{
            at, exprs[random.uintLessThan(usize, exprs.len)],
        });
    }

    try source.appendSlice(gpa, preamble);

    const count = random.intRangeAtMost(u32, 1, statements_max);
    for (0..count) |_| {
        const template = stmts[random.uintLessThan(usize, stmts.len)];
        try source.appendSlice(gpa, "    ");
        var rest = template;
        while (std.mem.indexOf(u8, rest, "$E")) |at| {
            try source.appendSlice(gpa, rest[0..at]);
            try source.appendSlice(gpa, exprs[random.uintLessThan(usize, exprs.len)]);
            rest = rest[at + "$E".len ..];
        }
        try source.appendSlice(gpa, rest);
        try source.append(gpa, '\n');
    }

    try source.appendSlice(gpa, epilogue);
    assert(source.items.len < source_bytes_max);
}
