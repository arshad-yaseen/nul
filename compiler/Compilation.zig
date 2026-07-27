//! Runs one file through the whole pipeline and keeps what a reader needs afterwards.
//!
//! Everything a diagnostic points at is either a token index into `tree` or a string in
//! the diagnostics arena, so the pool and the namespace are gone by the time this
//! returns. Only the three things `render` needs survive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Lower = @import("Lower.zig");
const Namespace = @import("Namespace.zig");
const Region = @import("Region.zig");
const Sema = @import("Sema.zig");
const Source = @import("Source.zig");

const Compilation = @This();

src: Source,
tree: Ast,
diagnostics: Diagnostic.List,

pub const Error = Allocator.Error || Source.LoadError;

/// Checks `path`, stopping after parsing if the file does not parse at all.
pub fn check(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Compilation {
    var src = try Source.load(gpa, io, dir, path);
    errdefer src.deinit(gpa);

    var tree = try Ast.parse(gpa, src.bytes);
    errdefer tree.deinit(gpa);

    var diagnostics: Diagnostic.List = .init(gpa);
    errdefer diagnostics.deinit();

    // A tree with holes in it would only produce errors about the holes.
    if (tree.errors.len == 0) try analyze(gpa, &tree, &diagnostics);
    diagnostics.sortBySource();

    return .{ .src = src, .tree = tree, .diagnostics = diagnostics };
}

fn analyze(gpa: Allocator, tree: *Ast, diagnostics: *Diagnostic.List) Allocator.Error!void {
    var pool = try InternPool.init(gpa);
    defer pool.deinit(gpa);

    var namespace = try Namespace.collect(gpa, tree, diagnostics);
    defer namespace.deinit(gpa);

    var sema: Sema = .{
        .gpa = gpa,
        .pool = &pool,
        .tree = tree,
        .namespace = &namespace,
        .diagnostics = diagnostics,
    };
    defer sema.deinit();
    try sema.resolveDeclarations();

    for (namespace.all()) |decl| {
        if (tree.nodeTag(decl.node) != .fn_decl) continue;
        var body = try Lower.run(&sema, decl);
        defer body.deinit(gpa);
        try Region.run(gpa, &pool, tree, diagnostics, body);
    }
}

pub fn deinit(c: *Compilation, gpa: Allocator) void {
    c.diagnostics.deinit();
    c.tree.deinit(gpa);
    c.src.deinit(gpa);
    c.* = undefined;
}

pub fn errorCount(c: *const Compilation) usize {
    return if (c.tree.errors.len > 0) c.tree.errors.len else c.diagnostics.all().len;
}

pub fn render(
    c: *Compilation,
    gpa: Allocator,
    w: *Io.Writer,
    palette: Diagnostic.Palette,
) Diagnostic.Error!void {
    if (c.tree.errors.len > 0) {
        return Diagnostic.renderAll(gpa, c.tree.errors, c.tree, &c.src, w, palette);
    }
    try Diagnostic.renderAll(gpa, c.diagnostics.all(), c.tree, &c.src, w, palette);
}
