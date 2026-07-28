//! Runs one file through the whole pipeline and keeps what a reader needs afterwards.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const dump_nir = @import("dump.zig");
const Type = @import("Type.zig");
const Lower = @import("Lower.zig");
const Namespace = @import("Namespace.zig");
const Nir = @import("Nir.zig");
const Sema = @import("Sema.zig");
const Source = @import("Source.zig");

const Compilation = @This();

src: Source,
tree: Ast,
diagnostics: Diagnostic.List,

pub const Error = Allocator.Error || Source.LoadError || Io.Writer.Error;

pub fn check(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Compilation {
    return run(gpa, io, dir, path, null);
}

/// Checks `path` and writes its IR to `out`.
pub fn dump(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, out: *Io.Writer) Error!Compilation {
    return run(gpa, io, dir, path, out);
}

fn run(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    out: ?*Io.Writer,
) Error!Compilation {
    var src = try Source.load(gpa, io, dir, path);
    errdefer src.deinit(gpa);

    var tree = try Ast.parse(gpa, src.bytes);
    errdefer tree.deinit(gpa);

    var diagnostics: Diagnostic.List = .init(gpa);
    errdefer diagnostics.deinit();

    // A tree with holes in it would only produce errors about the holes.
    if (tree.errors.len == 0) try analyze(gpa, &tree, &diagnostics, out);
    diagnostics.sortBySource();

    return .{ .src = src, .tree = tree, .diagnostics = diagnostics };
}

fn analyze(
    gpa: Allocator,
    tree: *Ast,
    diagnostics: *Diagnostic.List,
    out: ?*Io.Writer,
) Error!void {
    var types = try Type.init(gpa);
    defer types.deinit(gpa);

    var namespace = try Namespace.collect(gpa, tree, diagnostics);
    defer namespace.deinit(gpa);

    var sema: Sema = .{
        .gpa = gpa,
        .types = &types,
        .tree = tree,
        .namespace = &namespace,
        .diagnostics = diagnostics,
    };
    defer sema.deinit();
    try sema.resolveDeclarations();

    var functions: std.ArrayList(Nir.Function) = .empty;
    defer {
        for (functions.items) |*f| f.body.deinit(gpa);
        functions.deinit(gpa);
    }

    for (namespace.all()) |decl| {
        if (tree.nodeTag(decl.node) != .fn_decl) continue;
        const body = try Lower.run(&sema, decl);
        try functions.append(gpa, .{ .decl = decl, .body = body });
    }

    if (out) |w| try dump_nir.write(gpa, &types, tree, functions.items, w);
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
