const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const compiler = @import("compiler");

/// The directory a test lives in decides what is expected of it.
const Kind = enum {
    /// Must parse. The golden is its tree.
    parse,
    /// Must not parse. The golden is its diagnostics.
    @"parse-error",
    /// Bytes chosen to break the compiler rather than the language. That there
    /// is a golden rather than a stack trace is the point.
    hostile,

    fn extension(kind: Kind) []const u8 {
        assert(@intFromEnum(kind) <= @intFromEnum(Kind.hostile));
        return switch (kind) {
            .parse => ".tree",
            .@"parse-error", .hostile => ".expected",
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

    var source: compiler.Source = try .load(gpa, io, .cwd(), path);
    defer source.deinit(gpa);

    var tree = try compiler.AST.parse(gpa, source.bytes);
    defer tree.deinit(gpa);

    // the dump has to survive every tree, including one made mostly of holes
    var sink: Writer.Discarding = .init(&.{});
    try compiler.dump(tree, &sink.writer);

    var actual: Writer.Allocating = .init(gpa);
    defer actual.deinit();

    switch (kind) {
        .parse => {
            if (tree.errors.len > 0) {
                try log.print("{s}: expected to parse, but\n", .{path});
                try renderAll(gpa, &source, tree, log);
                return false;
            }
            try compiler.dump(tree, &actual.writer);
        },
        .@"parse-error" => {
            if (tree.errors.len == 0) {
                try log.print("{s}: expected a diagnostic, got none\n", .{path});
                return false;
            }
            try renderAll(gpa, &source, tree, &actual.writer);
        },
        .hostile => if (tree.errors.len > 0)
            try renderAll(gpa, &source, tree, &actual.writer)
        else
            try compiler.dump(tree, &actual.writer),
    }

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

fn renderAll(
    gpa: Allocator,
    source: *compiler.Source,
    tree: compiler.AST,
    writer: *Writer,
) !void {
    assert(tree.errors.len > 0);
    for (tree.errors) |diagnostic| try diagnostic.render(gpa, source, writer, .off);
}

fn kindOf(path: []const u8) ?Kind {
    assert(path.len > 0);
    if (std.mem.endsWith(u8, path, ".nul") == false) return null;

    const directory = std.fs.path.dirname(path) orelse return null;
    return std.meta.stringToEnum(Kind, std.fs.path.basename(directory));
}
