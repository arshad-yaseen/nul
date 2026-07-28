//! What a pass records when something is wrong, and the renderer that draws it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const Source = @import("Source.zig");

const Diagnostic = @This();

// What a pass records

/// Explicit and permanent: `E0007` means one thing forever. A kind may be retired,
/// never renumbered. Semantic errors own E00xx, `Ast.Error.Tag` owns E01xx.
pub const Tag = enum(u16) {
    redeclared = 1,
    shadows_builtin = 2,
    undefined_name = 3,
    depends_on_itself = 4,
    not_a_type = 5,
    type_mismatch = 6,
    unsupported_value = 7,
    invalid_digit = 8,
    literal_too_large = 9,
    multiple_arenas = 10,
    not_mutable = 11,
    not_assignable = 12,
    no_such_field = 13,
    not_callable = 14,
    wrong_arg_count = 15,
    copy_holds_pointer = 16,
    does_not_live_long_enough = 17,
    release_needs_a_name = 18,
    used_after_release = 19,
    out_of_range = 20,
    division_by_zero = 21,
    comptime_overflow = 22,
    missing_return = 23,
    not_in_a_loop = 24,
};

/// One recorded mistake. Most need only a tag and a token, which costs no allocation;
/// everything below `token` is owned by the `List` and usually empty.
pub const Entry = struct {
    tag: Tag,
    /// The primary span, what the header points at and what sorting orders on.
    token: Ast.TokenIndex,
    /// Null covers `token` alone.
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
            .unsupported_value => try w.writeAll("this expression is not supported yet"),
            .invalid_digit => try w.print("'{s}' is not a valid number", .{name}),
            .literal_too_large => try w.print("'{s}' does not fit any integer type", .{name}),
            .multiple_arenas => try w.writeAll(
                "this function takes more than one arena, so its result has no single home",
            ),
            .not_mutable => try w.print("'{s}' is a 'let', so it cannot be assigned to", .{name}),
            .not_assignable => try w.writeAll("cannot assign to this expression"),
            .no_such_field => try w.print("no field named '{s}'", .{name}),
            .not_callable => try w.writeAll("this is not a function"),
            .wrong_arg_count => try w.writeAll("wrong number of arguments"),
            .copy_holds_pointer => try w.writeAll(
                "this type holds a pointer, so copying it would relabel memory it does not own",
            ),
            .does_not_live_long_enough => try w.print("'{s}' does not live long enough", .{name}),
            .release_needs_a_name => try w.writeAll("an arena can only be released by name"),
            .used_after_release => try w.print("'{s}' is used after its arena was released", .{name}),
            .out_of_range => try w.writeAll("this value does not fit its type"),
            .division_by_zero => try w.writeAll("division by zero"),
            .comptime_overflow => try w.writeAll("this computation is too large to represent"),
            .missing_return => try w.writeAll("not every path through this function returns a value"),
            .not_in_a_loop => try w.print("'{s}' is not inside a loop", .{name}),
        }
    }
};

pub const Mark = struct {
    token: Ast.TokenIndex,
    last: ?Ast.TokenIndex = null,
    text: []const u8 = "",
};

pub const Note = struct {
    kind: Kind,
    /// A newline starts a continuation line. Wrapping is the producer's.
    text: []const u8,
    /// Suggested code. With `at` set it is drawn as a diff of that line.
    code: []const u8 = "",
    /// Byte offset on the line `code` replaces.
    at: ?u32 = null,

    pub const Kind = enum { note, help };
};

/// Everything a diagnostic points at dies with the compilation, so one arena owns the
/// entries and every string they reach.
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

    pub fn allocator(list: *List) Allocator {
        return list.arena.allocator();
    }

    pub fn add(list: *List, entry: Entry) Allocator.Error!void {
        @branchHint(.cold);
        try list.items.append(list.allocator(), entry);
    }

    pub fn all(list: *const List) []const Entry {
        return list.items.items;
    }

    pub fn print(list: *List, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(list.allocator(), fmt, args);
    }

    pub fn mark(list: *List, token: Ast.TokenIndex, text: []const u8) Allocator.Error![]const Mark {
        return list.marks(&.{.{ .token = token, .text = text }});
    }

    pub fn marks(list: *List, values: []const Mark) Allocator.Error![]const Mark {
        return list.allocator().dupe(Mark, values);
    }

    pub fn notes(list: *List, values: []const Note) Allocator.Error![]const Note {
        return list.allocator().dupe(Note, values);
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

// What the renderer draws

message: []const u8,
code: ?u16 = null,
/// Any order, since the renderer sorts. Exactly one `.primary`, which fixes the header.
labels: []const Label,
notes: []const Note = &.{},

pub const Error = Allocator.Error || Io.Writer.Error;

pub const Label = struct {
    /// Half-open. A span past its first line is drawn as if it stopped there, since a
    /// marker only ever spans one row.
    start: u32,
    end: u32,
    style: Style = .secondary,
    text: []const u8 = "",

    pub const Style = enum { primary, secondary };
};

/// Four steps of loudness: the frame recedes furthest, annotations sit below the source
/// they describe, source reads plain, red marks what is wrong. A help note shares its
/// green with the `+` line it introduces.
pub const Palette = struct {
    reset: []const u8 = "",
    fail: []const u8 = "",
    bold: []const u8 = "",
    frame: []const u8 = "",
    primary: []const u8 = "",
    secondary: []const u8 = "",
    note: []const u8 = "",
    help: []const u8 = "",
    removed: []const u8 = "",
    added: []const u8 = "",

    pub const plain: Palette = .{};

    pub const ansi: Palette = .{
        .reset = "\x1b[0m",
        .fail = "\x1b[1;31m",
        .bold = "\x1b[1m",
        .frame = "\x1b[90m",
        .primary = "\x1b[31m",
        .secondary = "\x1b[34m",
        .note = "\x1b[1;36m",
        .help = "\x1b[1;32m",
        .removed = "\x1b[31m",
        .added = "\x1b[32m",
    };
};

/// Takes `Ast.Error`s as readily as `Entry`s, since both word themselves with `render`
/// and point at a `token`. That is why a parse error and a type error look the same.
pub fn renderAll(
    gpa: Allocator,
    entries: anytype,
    tree: Ast,
    src: *Source,
    w: *Io.Writer,
    palette: Palette,
) Error!void {
    var wording: Io.Writer.Allocating = .init(gpa);
    defer wording.deinit();

    for (entries, 0..) |entry, at| {
        if (at > 0) try w.writeByte('\n');
        // An `Ast.Error` carries none of these, where an `Entry` may.
        const extras: Extras = if (@hasField(@TypeOf(entry), "marks")) .{
            .message = entry.message,
            .last = entry.last,
            .text = entry.text,
            .marks = entry.marks,
            .notes = entry.notes,
        } else .{};

        const message = if (extras.message.len > 0) extras.message else blk: {
            wording.clearRetainingCapacity();
            try entry.render(tree, &wording.writer);
            break :blk wording.written();
        };

        const labels = try gpa.alloc(Label, 1 + extras.marks.len);
        defer gpa.free(labels);
        labels[0] = spanOf(tree, entry.token, extras.last, .primary, extras.text);
        for (extras.marks, labels[1..]) |m, *label| {
            label.* = spanOf(tree, m.token, m.last, .secondary, m.text);
        }

        const d: Diagnostic = .{
            .message = message,
            .code = @intFromEnum(entry.tag),
            .labels = labels,
            .notes = extras.notes,
        };
        try d.render(gpa, src, w, palette);
    }
}

const Extras = struct {
    message: []const u8 = "",
    last: ?Ast.TokenIndex = null,
    text: []const u8 = "",
    marks: []const Mark = &.{},
    notes: []const Note = &.{},
};

fn spanOf(tree: Ast, token: Ast.TokenIndex, last: ?Ast.TokenIndex, style: Label.Style, text: []const u8) Label {
    const end = last orelse token;
    return .{
        .start = tree.tokenStart(token),
        .end = tree.tokenStart(end) + @as(u32, @intCast(tree.tokenSlice(end).len)),
        .style = style,
        .text = text,
    };
}

/// Columns are 1-based bytes. `end_col` is exclusive and always past `col`, so every
/// label draws at least one marker.
const Placed = struct {
    line: u32,
    col: u32,
    end_col: u32,
    style: Label.Style,
    text: []const u8,

    fn before(_: void, a: Placed, b: Placed) bool {
        return if (a.line != b.line) a.line < b.line else a.col < b.col;
    }
};

pub fn render(
    d: Diagnostic,
    gpa: Allocator,
    src: *Source,
    w: *Io.Writer,
    palette: Palette,
) Error!void {
    assert(d.labels.len > 0);

    const placed = try gpa.alloc(Placed, d.labels.len);
    defer gpa.free(placed);

    var header: ?Placed = null;
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

    // A suggested line shares the snippet's gutter, so it counts toward the width.
    for (d.notes) |n| if (n.at) |offset| {
        last_line = @max(last_line, (try src.lineCol(gpa, offset)).line);
    };

    std.mem.sort(Placed, placed, {}, Placed.before);

    var r: Render = .{
        .w = w,
        .gpa = gpa,
        .src = src,
        .palette = palette,
        .gutter = digitCount(last_line),
    };

    try r.tint(palette.fail, "error");
    if (d.code) |code| try r.print(palette.fail, "[E{d:0>4}]", .{code});
    try r.tint(palette.bold, ": ");
    try r.tint(palette.bold, d.message);
    try w.writeAll("\n\n");

    try w.splatByteAll(' ', r.gutter + 1);
    try r.tint(palette.frame, "┌─ ");
    try r.print(palette.frame, "{s}:{d}:{d}\n", .{ src.path, header.?.line, header.?.col });
    try r.frame("│");

    var i: usize = 0;
    var prev: u32 = 0;
    while (i < placed.len) {
        const line = placed[i].line;
        var j = i;
        while (j < placed.len and placed[j].line == line) j += 1;
        const group = placed[i..j];

        if (prev != 0 and line > prev + 1) try r.frame("·");
        try r.numbered(line);
        try r.print("", "{s}\n", .{try src.lineText(gpa, line)});
        try r.markerRow(group);

        // The rightmost label spoke on the marker row. Of the rest, only those with
        // something to say need a connector, drawn right to left so none crosses another.
        var speaking: usize = 0;
        for (group[0 .. group.len - 1]) |label| {
            if (label.text.len == 0) continue;
            group[speaking] = label;
            speaking += 1;
        }
        const queued = group[0..speaking];
        if (queued.len > 0) {
            try r.connectorRow(queued, queued.len, "", .secondary);
            var k = queued.len;
            while (k > 0) {
                k -= 1;
                try r.connectorRow(queued, k, queued[k].text, queued[k].style);
            }
        }

        prev = line;
        i = j;
    }

    // Each note gets its own air, so a wall of prose does not follow the snippet.
    for (d.notes) |n| {
        try r.frame("│");
        try r.note(n);
    }
    try r.frame("│");
}

/// Holds what every row needs, so no helper takes the palette as a parameter.
const Render = struct {
    w: *Io.Writer,
    gpa: Allocator,
    src: *Source,
    palette: Palette,
    gutter: u32,

    fn tint(r: Render, color: []const u8, text: []const u8) Io.Writer.Error!void {
        return r.print(color, "{s}", .{text});
    }

    fn print(r: Render, color: []const u8, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        try r.w.writeAll(color);
        try r.w.print(fmt, args);
        try r.untint(color);
    }

    fn untint(r: Render, color: []const u8) Io.Writer.Error!void {
        if (color.len > 0) try r.w.writeAll(r.palette.reset);
    }

    fn styleOf(r: Render, style: Label.Style) []const u8 {
        return switch (style) {
            .primary => r.palette.primary,
            .secondary => r.palette.secondary,
        };
    }

    /// `│` between rows, `·` where lines were skipped.
    fn frame(r: Render, glyph: []const u8) Io.Writer.Error!void {
        try r.w.splatByteAll(' ', r.gutter + 1);
        try r.tint(r.palette.frame, glyph);
        try r.w.writeByte('\n');
    }

    fn numbered(r: Render, line: u32) Io.Writer.Error!void {
        try r.w.splatByteAll(' ', r.gutter - digitCount(line));
        try r.print(r.palette.frame, "{d} │ ", .{line});
    }

    fn bar(r: Render) Io.Writer.Error!void {
        try r.w.splatByteAll(' ', r.gutter + 1);
        try r.tint(r.palette.frame, "│");
        try r.w.writeByte(' ');
    }

    /// The `^^^` and `───` under a source line, plus the rightmost label's text.
    fn markerRow(r: Render, group: []const Placed) Io.Writer.Error!void {
        try r.bar();
        var col: u32 = 1;
        for (group) |g| {
            try r.w.splatByteAll(' ', g.col -| col);
            const color = r.styleOf(g.style);
            try r.w.writeAll(color);
            var c = @max(g.col, col);
            while (c < g.end_col) : (c += 1) {
                try r.w.writeAll(if (g.style == .primary) "^" else "─");
            }
            try r.untint(color);
            col = @max(col, g.end_col);
        }

        const last = group[group.len - 1];
        if (last.text.len > 0) {
            try r.w.writeAll("  ");
            try r.tint(r.styleOf(last.style), last.text);
        }
        try r.w.writeByte('\n');
    }

    /// `│` under the first `connected` queued labels, then `text` on an elbow at the next.
    fn connectorRow(
        r: Render,
        queued: []const Placed,
        connected: usize,
        text: []const u8,
        style: Label.Style,
    ) Io.Writer.Error!void {
        try r.bar();
        var col: u32 = 1;
        for (queued[0..connected]) |label| {
            try r.w.splatByteAll(' ', label.col -| col);
            try r.tint(r.styleOf(label.style), "│");
            col = label.col + 1;
        }
        if (text.len > 0) {
            try r.w.splatByteAll(' ', queued[connected].col -| col);
            const color = r.styleOf(style);
            try r.w.writeAll(color);
            try r.w.writeAll("└─ ");
            try r.w.writeAll(text);
            try r.untint(color);
        }
        try r.w.writeByte('\n');
    }

    fn note(r: Render, n: Note) Error!void {
        try r.w.splatByteAll(' ', r.gutter + 1);
        try r.tint(r.palette.frame, "= ");
        try r.print(switch (n.kind) {
            .note => r.palette.note,
            .help => r.palette.help,
        }, "{s}: ", .{@tagName(n.kind)});
        try r.wrapped(n.text, r.gutter + 9, false);

        if (n.code.len == 0) return;
        if (n.at) |offset| return r.diff(offset, n.code);
        try r.wrapped(n.code, r.gutter + 11, true);
    }

    /// The line as it is, then as it would be. Indentation comes from the original, so
    /// the two read as one edit.
    fn diff(r: Render, offset: u32, code: []const u8) Error!void {
        const line = (try r.src.lineCol(r.gpa, offset)).line;
        const original = try r.src.lineText(r.gpa, line);
        var lead: usize = 0;
        while (lead < original.len and (original[lead] == ' ' or original[lead] == '\t')) lead += 1;

        try r.frame("│");
        try r.numbered(line);
        try r.print(r.palette.removed, "- {s}\n", .{original});

        try r.numbered(line);
        try r.print(r.palette.added, "+ {s}{s}\n", .{ original[0..lead], code });
    }

    /// Indents every line after the first. Suggested code wants the first indented too.
    fn wrapped(r: Render, text: []const u8, indent: u32, indent_first: bool) Io.Writer.Error!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| : (first = false) {
            if (indent_first or !first) try r.w.splatByteAll(' ', indent);
            try r.w.writeAll(line);
            try r.w.writeByte('\n');
        }
    }
};

fn digitCount(n: u32) u32 {
    return std.math.log10_int(@max(n, 1)) + 1;
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
    try d.render(gpa, &src, &out.writer, .plain);

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
        \\  │ └─ this memory lives in 'arena'
        \\  │
        \\  = note: 'scratch' is a child of 'arena', and a child dies
        \\          before its parent.
        \\  │
        \\  = help: copy the value into the arena that outlives it
        \\            box.item = arena.copy(temp)
        \\  │
        \\
    , out.written());
}

test "renders a suggestion as a diff of the line it replaces" {
    const gpa = std.testing.allocator;
    const text =
        \\fn build(arena: Arena) *Span {
        \\    var probe = makeSpan(scratch, 0, pos)
        \\    return probe
        \\
    ;
    var src: Source = .{ .path = "build.nul", .bytes = text };
    defer if (src.line_starts) |starts| gpa.free(starts);

    const start: u32 = @intCast(std.mem.indexOf(u8, text, "probe =").?);
    const d: Diagnostic = .{
        .message = "'probe' does not live long enough",
        .labels = &.{
            .{ .start = start, .end = start + 5, .style = .primary, .text = "this lives in 'scratch'" },
        },
        .notes = &.{.{
            .kind = .help,
            .text = "allocate it from 'arena' instead of 'scratch'",
            .code = "var probe = makeSpan(arena, 0, pos)",
            .at = start,
        }},
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try d.render(gpa, &src, &out.writer, .plain);

    try std.testing.expectEqualStrings(
        \\error: 'probe' does not live long enough
        \\
        \\  ┌─ build.nul:2:9
        \\  │
        \\2 │     var probe = makeSpan(scratch, 0, pos)
        \\  │         ^^^^^  this lives in 'scratch'
        \\  │
        \\  = help: allocate it from 'arena' instead of 'scratch'
        \\  │
        \\2 │ -     var probe = makeSpan(scratch, 0, pos)
        \\2 │ +     var probe = makeSpan(arena, 0, pos)
        \\  │
        \\
    , out.written());
}
