//! A source file in a buffer the tokenizer can scan without bounds checks.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Source = @This();

/// One zero past the end is as far ahead as any scanner looks.
pub const padding = 1;

pub const max_bytes = std.math.maxInt(u32) - padding - 1;

path: []const u8,
bytes: [:0]const u8,
line_starts: ?[]u32 = null,

pub const LoadError = error{ SourceTooLarge, OutOfMemory, ReadFailed };

pub fn load(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) LoadError!Source {
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

/// Where each line starts, built on first use.
fn lineStarts(src: *Source, gpa: Allocator) Allocator.Error![]u32 {
    return src.line_starts orelse blk: {
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
}

pub fn lineCol(src: *Source, gpa: Allocator, offset: u32) Allocator.Error!LineCol {
    const starts = try src.lineStarts(gpa);
    const line = std.sort.upperBound(u32, starts, offset, struct {
        fn order(ctx: u32, item: u32) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.order) - 1;
    return .{ .line = @intCast(line + 1), .col = offset - starts[line] + 1 };
}

/// A 1-based line without its terminator. Out of range is empty, so a diagnostic
/// pointing past the end still renders.
pub fn lineText(src: *Source, gpa: Allocator, line: u32) Allocator.Error![]const u8 {
    const starts = try src.lineStarts(gpa);
    if (line == 0 or line > starts.len) return "";
    const start = starts[line - 1];
    const end = if (line < starts.len) starts[line] - 1 else @as(u32, @intCast(src.bytes.len));
    const text = src.bytes[start..end];
    return if (std.mem.endsWith(u8, text, "\r")) text[0 .. text.len - 1] else text;
}
