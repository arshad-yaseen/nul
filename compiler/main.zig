//! ./zig-out/bin/nul example/hello.nul

const std = @import("std");
const Io = std.Io;

const Source = @import("Source.zig");
const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("Ast.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &buf);
    const w = &out_file.interface;
    defer w.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try w.writeAll("usage: nul <file.nul>\n");
        return 1;
    }
    const path = args[1];

    var src = Source.load(gpa, io, Io.Dir.cwd(), path) catch |e| {
        try w.print("nul: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer src.deinit(gpa);

    var tree = try Ast.parse(gpa, src.bytes);
    defer tree.deinit(gpa);

    if (tree.errors.len == 0) return 0;

    try w.writeByte('\n');

    for (tree.errors) |err| {
        const lc = try src.lineCol(gpa, tree.tokenStart(err.token));
        try w.print("{s}:{d}:{d}: error: ", .{ path, lc.line, lc.col });
        try err.render(tree, w);
        try w.writeByte('\n');
    }
    return 1;
}
