//! A source file in a buffer the tokenizer can scan without bounds checks.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Source = @This();

pub const padding = 16;

pub const max_bytes = std.math.maxInt(u32) - padding - 1;

path: []const u8,
bytes: [:0]const u8,
line_starts: ?[]u32 = null,

pub fn load(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) error{ SourceTooLarge, OutOfMemory, ReadFailed }!Source {
    var file = dir.openFile(io, path, .{}) catch return error.ReadFailed;
    defer file.close(io);

    const stat = file.stat(io) catch return error.ReadFailed;
    if (stat.size > max_bytes) return error.SourceTooLarge;
    const len: usize = @intCast(stat.size);

    const buf = try gpa.alloc(u8, len + padding);
    errdefer gpa.free(buf);

    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(buf[0..len]) catch return error.ReadFailed;
    @memset(buf[len..], 0);

    return .{ .path = path, .bytes = buf[0..len :0] };
}

pub fn deinit(src: *Source, gpa: Allocator) void {
    gpa.free(src.bytes.ptr[0 .. src.bytes.len + padding]);
    if (src.line_starts) |ls| gpa.free(ls);
    src.* = undefined;
}

pub const LineCol = struct { line: u32, col: u32 };

/// Resolves a byte offset to a 1-based line and column.
pub fn lineCol(src: *Source, gpa: Allocator, offset: u32) Allocator.Error!LineCol {
    const starts = src.line_starts orelse blk: {
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(gpa);
        try list.append(gpa, 0);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, src.bytes, i, '\n')) |nl| : (i = nl + 1) {
            try list.append(gpa, @intCast(nl + 1));
        }
        src.line_starts = try list.toOwnedSlice(gpa);
        break :blk src.line_starts.?;
    };

    const line = std.sort.upperBound(u32, starts, offset, struct {
        fn order(ctx: u32, item: u32) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.order) - 1;
    return .{ .line = @intCast(line + 1), .col = offset - starts[line] + 1 };
}
