//! What a pass records when something is wrong, and the renderer that draws it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const Source = @import("Source.zig");

const Diagnostic = @This();

/// Says what is wrong, never where.
message: []const u8,
/// Any order; the renderer sorts. Exactly one `.primary`, which fixes the header.
labels: []const Label,
notes: []const Note = &.{},

pub const Label = struct {
    /// Half-open. A span past its first line is drawn as if it stopped there, since a
    /// marker only ever spans one row.
    start: u32,
    end: u32,
    style: Style = .secondary,
    text: []const u8 = "",

    pub const Style = enum {
        primary,
        secondary,

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
    /// A newline starts a continuation line. Wrapping is the producer's.
    text: []const u8,
    /// Suggested code, drawn two columns further in.
    code: []const u8 = "",

    pub const Kind = enum { note, help };
};

// What passes record

pub const Tag = enum {
    redeclared,
    shadows_builtin,
    undefined_name,
    depends_on_itself,
    not_a_type,
    type_mismatch,
    unsupported_value,
    invalid_digit,
    literal_too_large,
    multiple_arenas,
};

/// A secondary span with its own wording. Owned by the `List`.
pub const Mark = struct {
    token: Ast.TokenIndex,
    /// Last token of the span. Null covers `token` alone.
    last: ?Ast.TokenIndex = null,
    text: []const u8 = "",
};

/// One recorded mistake. Most need only a tag and a token, which costs no allocation,
/// everything below `token` is owned by the `List` and usually empty.
pub const Entry = struct {
    tag: Tag,
    /// The primary span: what the header points at, and what sorting orders on.
    token: Ast.TokenIndex,
    /// Last token of the primary span. Null covers `token` alone.
    last: ?Ast.TokenIndex = null,
    /// Overrides the tag's wording, for a headline naming something `token` does not.
    message: []const u8 = "",
    /// The primary label's text. Empty draws the marker alone.
    text: []const u8 = "",
    marks: []const Mark = &.{},
    notes: []const Note = &.{},

    /// The tag's default wording. `message` wins when it is set.
    pub fn render(entry: Entry, tree: Ast, w: *Io.Writer) Io.Writer.Error!void {
        const name = tree.tokenSlice(entry.token);
        switch (entry.tag) {
            .redeclared => try w.print("'{s}' is declared more than once", .{name}),
            .shadows_builtin => try w.print("'{s}' is a builtin type", .{name}),
            .undefined_name => try w.print("no declaration named '{s}'", .{name}),
            .depends_on_itself => try w.print("'{s}' depends on itself", .{name}),
            .not_a_type => try w.print("'{s}' is not a type", .{name}),
            .type_mismatch => try w.writeAll("the declared type does not match the value"),
            .unsupported_value => try w.writeAll(
                "evaluating this at compile time is not implemented yet",
            ),
            .invalid_digit => try w.print("'{s}' is not a valid number", .{name}),
            .literal_too_large => try w.print("'{s}' does not fit any integer type", .{name}),
            .multiple_arenas => try w.writeAll(
                "this function takes more than one arena, so its result has no single home",
            ),
        }
    }
};

/// Everything a diagnostic points at outlives the compilation and dies with it, so one
/// arena owns the entries and every string they reach.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Entry),

    pub fn init(gpa: Allocator) List {
        return .{ .arena = .init(gpa), .items = .empty };
    }

    pub fn deinit(list: *List) void {
        list.arena.deinit();
        list.* = undefined;
    }

    /// For the marks, notes and messages an `Entry` points at.
    pub fn allocator(list: *List) Allocator {
        return list.arena.allocator();
    }

    pub fn print(list: *List, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(list.allocator(), fmt, args);
    }

    pub fn add(list: *List, entry: Entry) Allocator.Error!void {
        @branchHint(.cold);
        try list.items.append(list.allocator(), entry);
    }

    pub fn all(list: *const List) []const Entry {
        return list.items.items;
    }

    /// Neither collection nor resolution runs in the reader's order.
    pub fn sortBySource(list: *List) void {
        std.mem.sort(Entry, list.items.items, {}, struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                return a.token < b.token;
            }
        }.before);
    }
};

// Rendering

pub const Error = Allocator.Error || Io.Writer.Error;

const Extras = struct {
    message: []const u8 = "",
    last: ?Ast.TokenIndex = null,
    text: []const u8 = "",
    marks: []const Mark = &.{},
    notes: []const Note = &.{},
};

/// An `Ast.Error` carries none of these; an `Entry` may.
fn extrasOf(entry: anytype) Extras {
    if (!@hasField(@TypeOf(entry), "marks")) return .{};
    return .{
        .message = entry.message,
        .last = entry.last,
        .text = entry.text,
        .marks = entry.marks,
        .notes = entry.notes,
    };
}

/// Takes `Ast.Error`s as readily as `Entry`s: both word themselves with `render` and
/// point at a `token`, which is why a parse error and a type error look the same.
pub fn renderAll(
    gpa: Allocator,
    entries: anytype,
    tree: Ast,
    src: *Source,
    w: *Io.Writer,
) Error!void {
    var wording: Io.Writer.Allocating = .init(gpa);
    defer wording.deinit();

    for (entries, 0..) |entry, at| {
        if (at > 0) try w.writeByte('\n');
        const extras = extrasOf(entry);

        const message = if (extras.message.len > 0) extras.message else blk: {
            wording.clearRetainingCapacity();
            try entry.render(tree, &wording.writer);
            break :blk wording.written();
        };

        const labels = try gpa.alloc(Label, 1 + extras.marks.len);
        defer gpa.free(labels);
        labels[0] = spanOf(tree, entry.token, extras.last, .primary, extras.text);
        for (extras.marks, labels[1..]) |mark, *label| {
            label.* = spanOf(tree, mark.token, mark.last, .secondary, mark.text);
        }

        const d: Diagnostic = .{ .message = message, .labels = labels, .notes = extras.notes };
        try d.render(gpa, src, w);
    }
}

fn spanOf(
    tree: Ast,
    token: Ast.TokenIndex,
    last: ?Ast.TokenIndex,
    style: Label.Style,
    text: []const u8,
) Label {
    const end_token = last orelse token;
    return .{
        .start = tree.tokenStart(token),
        .end = tree.tokenStart(end_token) + @as(u32, @intCast(tree.tokenSlice(end_token).len)),
        .style = style,
        .text = text,
    };
}

/// Columns are 1-based bytes; `end_col` is exclusive and always past `col`, so every
/// label draws at least one marker.
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
        // Zero-width still has to be visible, and one past the end is where
        // "found end of file" points.
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
    assert(header != null); // nothing to point at

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

        // Skipped lines collapse to one mark.
        if (prev_line != 0 and line > prev_line + 1) try writeGutterLine(w, gutter, "·");

        try w.splatByteAll(' ', gutter - digitCount(line));
        try w.print("{d} │ {s}\n", .{ line, try src.lineText(gpa, line) });

        try writeMarkerRow(w, gutter, group);

        // The rightmost label spoke on the marker row. The rest are drawn from the
        // right, so no connector crosses another's text.
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

/// `│` between snippet rows, `·` where lines were skipped.
fn writeGutterLine(w: *Io.Writer, gutter: u32, mark: []const u8) Io.Writer.Error!void {
    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll(mark);
    try w.writeByte('\n');
}

/// The `^^^` and `───` under a source line, plus the rightmost label's text.
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

/// `│` under the first `connected_count` queued labels, then `text` at the next one.
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

/// Indents every line after the first, suggested code wants the first indented too.
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

test "renders several labels and notes" {
    const gpa = std.testing.allocator;
    const text =
        \\var scratch = arena.child()
        \\var box = arena.create(Box)
        \\var temp = scratch.create(i64)
        \\box.item = temp
        \\
    ;
    var src: Source = .{ .path = "leak.nul", .bytes = text };
    // The bytes are static here, so only the built line table is ours to free.
    defer if (src.line_starts) |starts| gpa.free(starts);

    const at = struct {
        fn f(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.f;

    const d: Diagnostic = .{
        .message = "'temp' does not live long enough",
        .labels = &.{
            .{ .start = at("scratch ="), .end = at("scratch =") + 7, .text = "'scratch' is created here" },
            .{ .start = at("box ="), .end = at("box =") + 3, .text = "'box' lives in 'arena'" },
            .{ .start = at("temp ="), .end = at("temp =") + 4, .text = "'temp' lives in 'scratch'" },
            .{ .start = at("box.item"), .end = at("box.item") + 8, .text = "this memory lives in 'arena'" },
            .{ .start = at("temp\n"), .end = at("temp\n") + 4, .style = .primary, .text = "this points into 'scratch'" },
        },
        .notes = &.{
            .{ .kind = .note, .text = "'scratch' is a child of 'arena', and a child dies\nbefore its parent." },
            .{ .kind = .help, .text = "copy the value into the arena that outlives it", .code = "box.item = arena.copy(temp)" },
        },
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try d.render(gpa, &src, &out.writer);

    try std.testing.expectEqualStrings(
        \\error: 'temp' does not live long enough
        \\
        \\  ┌─ leak.nul:4:12
        \\  │
        \\1 │ var scratch = arena.child()
        \\  │     ───────  'scratch' is created here
        \\2 │ var box = arena.create(Box)
        \\  │     ───  'box' lives in 'arena'
        \\3 │ var temp = scratch.create(i64)
        \\  │     ────  'temp' lives in 'scratch'
        \\4 │ box.item = temp
        \\  │ ────────   ^^^^  this points into 'scratch'
        \\  │ │
        \\  │ this memory lives in 'arena'
        \\  │
        \\  = note: 'scratch' is a child of 'arena', and a child dies
        \\          before its parent.
        \\  = help: copy the value into the arena that outlives it
        \\            box.item = arena.copy(temp)
        \\
    , out.written());
}
