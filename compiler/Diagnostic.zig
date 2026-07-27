//! A compiler diagnostic, and the renderer that draws it over the source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const Source = @import("Source.zig");

const Diagnostic = @This();

/// The headline. Says what is wrong, never where.
message: []const u8,
/// Need not be in source order, the renderer sorts. Exactly one is `.primary`, and
/// that one fixes the `path:line:col` in the header.
labels: []const Label,
/// Drawn under the snippet, in order.
notes: []const Note = &.{},

pub const Label = struct {
    /// Half-open byte offsets. A span reaching past its first line is drawn as if it
    /// stopped at the end of that line, because a marker only ever spans one row.
    start: u32,
    end: u32,
    style: Style = .secondary,
    /// May be empty, which draws the marker and nothing after it.
    text: []const u8 = "",

    pub const Style = enum {
        primary,
        secondary,

        /// One column wide, which is not the same as one byte wide.
        fn marker(s: Style) []const u8 {
            return switch (s) {
                .primary => "^",
                .secondary => "─",
            };
        }
    };
};

pub const Note = struct {
    kind: Kind,
    /// A newline starts a continuation line, aligned under the first character of
    /// the text. Wrapping is the producer's, so the wording lands as it was written.
    text: []const u8,
    /// Suggested code, drawn two columns further in. May be several lines.
    code: []const u8 = "",

    pub const Kind = enum { note, help };
};

pub const Error = Allocator.Error || Io.Writer.Error;

/// A label resolved against the source. Columns are 1-based bytes, `end_col` is
/// exclusive and always greater than `col`, so every label draws at least one marker.
const PlacedLabel = struct {
    line: u32,
    col: u32,
    end_col: u32,
    style: Label.Style,
    text: []const u8,

    fn sortsBefore(_: void, a: PlacedLabel, b: PlacedLabel) bool {
        return if (a.line != b.line) a.line < b.line else a.col < b.col;
    }
};

pub fn render(d: Diagnostic, gpa: Allocator, src: *Source, w: *Io.Writer) Error!void {
    assert(d.labels.len > 0);

    const placed = try gpa.alloc(PlacedLabel, d.labels.len);
    defer gpa.free(placed);

    var header: ?PlacedLabel = null;
    var last_line: u32 = 0;
    for (d.labels, placed) |l, *p| {
        const lc = try src.lineCol(gpa, l.start);
        const line_len: u32 = @intCast((try src.lineText(gpa, lc.line)).len);
        // A zero-width span still has to be visible, and one past the last column is
        // where "expected something, found end of line" points.
        const width = @max(1, l.end -| l.start);
        p.* = .{
            .line = lc.line,
            .col = lc.col,
            .end_col = @min(lc.col + width, @max(lc.col + 1, line_len + 1)),
            .style = l.style,
            .text = l.text,
        };
        if (l.style == .primary and header == null) header = p.*;
        last_line = @max(last_line, lc.line);
    }
    assert(header != null); // a diagnostic without a primary label has nowhere to point

    std.mem.sort(PlacedLabel, placed, {}, PlacedLabel.sortsBefore);

    const gutter = digitCount(last_line);

    try w.print("error: {s}\n\n", .{d.message});

    try w.splatByteAll(' ', gutter + 1);
    try w.print("┌─ {s}:{d}:{d}\n", .{ src.path, header.?.line, header.?.col });
    try writeGutterLine(w, gutter, "│");

    var i: usize = 0;
    var prev_line: u32 = 0;
    while (i < placed.len) {
        const line = placed[i].line;
        var j = i;
        while (j < placed.len and placed[j].line == line) j += 1;
        const group = placed[i..j];

        // Lines the reader is not being shown collapse to one mark.
        if (prev_line != 0 and line > prev_line + 1) try writeGutterLine(w, gutter, "·");

        try w.splatByteAll(' ', gutter - digitCount(line));
        try w.print("{d} │ {s}\n", .{ line, try src.lineText(gpa, line) });

        try writeMarkerRow(w, gutter, group);

        // The rightmost label spoke on the marker row. The rest queue up under it,
        // and are drawn from the right so no connector crosses another's text.
        const queued = group[0 .. group.len - 1];
        if (queued.len > 0) {
            try writeConnectorRow(w, gutter, queued, queued.len, "");
            var k = queued.len;
            while (k > 0) {
                k -= 1;
                try writeConnectorRow(w, gutter, queued, k, queued[k].text);
            }
        }

        prev_line = line;
        i = j;
    }

    try writeGutterLine(w, gutter, "│");

    for (d.notes) |n| {
        try w.splatByteAll(' ', gutter + 1);
        try w.print("= {s}: ", .{@tagName(n.kind)});
        try writeIndented(w, n.text, gutter + 9, false);
        if (n.code.len > 0) try writeIndented(w, n.code, gutter + 11, true);
    }
}

/// A gutter-only line, `│` between snippet rows and `·` where lines were skipped.
fn writeGutterLine(w: *Io.Writer, gutter: u32, mark: []const u8) Io.Writer.Error!void {
    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll(mark);
    try w.writeByte('\n');
}

/// The row of `^^^` and `───` under a source line, plus the rightmost label's text.
fn writeMarkerRow(w: *Io.Writer, gutter: u32, group: []const PlacedLabel) Io.Writer.Error!void {
    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("│ ");

    var col: u32 = 1;
    for (group) |g| {
        try w.splatByteAll(' ', g.col -| col);
        var c = @max(g.col, col);
        while (c < g.end_col) : (c += 1) try w.writeAll(g.style.marker());
        col = @max(col, g.end_col);
    }

    const last = group[group.len - 1];
    if (last.text.len > 0) try w.print("  {s}", .{last.text});
    try w.writeByte('\n');
}

/// A row of `│` under the first `connected_count` queued labels, then `text` at the
/// column of the label just past them.
fn writeConnectorRow(
    w: *Io.Writer,
    gutter: u32,
    queued: []const PlacedLabel,
    connected_count: usize,
    text: []const u8,
) Io.Writer.Error!void {
    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("│");
    if (connected_count == 0 and text.len == 0) return w.writeByte('\n');
    try w.writeByte(' ');

    var col: u32 = 1;
    for (queued[0..connected_count]) |label| {
        try w.splatByteAll(' ', label.col -| col);
        try w.writeAll("│");
        col = label.col + 1;
    }
    if (text.len > 0) {
        try w.splatByteAll(' ', queued[connected_count].col -| col);
        try w.writeAll(text);
    }
    try w.writeByte('\n');
}

/// Writes `text`, indenting every line after the first to `indent`. Suggested code
/// wants the first line indented too.
fn writeIndented(
    w: *Io.Writer,
    text: []const u8,
    indent: u32,
    indent_first_line: bool,
) Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var is_first = true;
    while (lines.next()) |line| : (is_first = false) {
        if (indent_first_line or !is_first) try w.splatByteAll(' ', indent);
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

fn digitCount(n: u32) u32 {
    var count: u32 = 1;
    var rest = n / 10;
    while (rest > 0) : (rest /= 10) count += 1;
    return count;
}
