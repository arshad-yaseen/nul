//! Runs the file tests. Everything under `pass/` must check clean, and everything under
//! `fail/` must say exactly what its `.expected` snapshot says. `--update` rewrites the
//! snapshots from what the compiler says now, so read the diff before committing it.

const std = @import("std");
const Io = std.Io;

const compiler = @import("compiler");
const Compilation = compiler.Compilation;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const cwd = Io.Dir.cwd();

    var update = false;
    var total: usize = 0;
    var failed: usize = 0;

    for (args[1..]) |path| {
        if (std.mem.eql(u8, path, "--update")) {
            update = true;
            continue;
        }
        total += 1;

        var result = Compilation.check(gpa, io, cwd, path) catch |err| {
            failed += 1;
            try w.print("FAIL {s}: cannot check: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer result.deinit(gpa);

        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try result.render(gpa, &out.writer, .plain);
        const got = out.written();

        if (std.mem.indexOf(u8, path, "pass/") != null) {
            if (result.errorCount() == 0) continue;
            failed += 1;
            try w.print("FAIL {s}: expected no errors\n\n{s}\n", .{ path, got });
            continue;
        }

        if (result.errorCount() == 0) {
            failed += 1;
            try w.print("FAIL {s}: expected errors, and the compiler found nothing\n", .{path});
            continue;
        }

        const snapshot = try std.fmt.allocPrint(arena, "{s}.expected", .{
            path[0 .. path.len - ".nul".len],
        });
        if (update) {
            try writeFile(io, cwd, snapshot, got);
            continue;
        }
        const expected = readFile(gpa, io, cwd, snapshot) catch {
            failed += 1;
            try w.print("FAIL {s}: no snapshot; run 'zig build test-update'\n", .{path});
            continue;
        };
        defer gpa.free(expected);
        if (!std.mem.eql(u8, got, expected)) {
            failed += 1;
            try w.print("FAIL {s}: output changed; 'zig build test-update' if it should\n" ++
                "---- expected ----\n{s}---- got ----\n{s}", .{ path, expected, got });
        }
    }

    if (failed > 0) {
        try w.print("\n{d} of {d} file tests failed\n", .{ failed, total });
        return 1;
    }
    try w.print("all {d} file tests passed\n", .{total});
    return 0;
}

fn readFile(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast((try file.stat(io)).size);
    const bytes = try gpa.alloc(u8, size);
    errdefer gpa.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

fn writeFile(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
