//! Runs one file through the whole pipeline and keeps what a reader needs afterwards.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const codegen_c = @import("codegen/c.zig");
const InternPool = @import("InternPool.zig");
const Lower = @import("Lower.zig");
const Namespace = @import("Namespace.zig");
const Nir = @import("Nir.zig");
const Region = @import("Region.zig");
const Sema = @import("Sema.zig");
const Source = @import("Source.zig");

const Compilation = @This();

src: Source,
tree: Ast,
diagnostics: Diagnostic.List,

pub const Error = Allocator.Error || Source.LoadError || Io.Writer.Error;

pub fn check(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Compilation {
    return build(gpa, io, dir, path, null);
}

/// Checks `path`, and writes C to `emit` when nothing is wrong with it. Emission happens
/// here because the pool and the bodies are alive only for the length of this call.
pub fn build(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    emit: ?*Io.Writer,
) Error!Compilation {
    var src = try Source.load(gpa, io, dir, path);
    errdefer src.deinit(gpa);

    var tree = try Ast.parse(gpa, src.bytes);
    errdefer tree.deinit(gpa);

    var diagnostics: Diagnostic.List = .init(gpa);
    errdefer diagnostics.deinit();

    // A tree with holes in it would only produce errors about the holes.
    if (tree.errors.len == 0) try analyze(gpa, &tree, &diagnostics, emit);
    diagnostics.sortBySource();

    return .{ .src = src, .tree = tree, .diagnostics = diagnostics };
}

fn analyze(
    gpa: Allocator,
    tree: *Ast,
    diagnostics: *Diagnostic.List,
    emit: ?*Io.Writer,
) Error!void {
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

    var functions: std.ArrayList(Nir.Function) = .empty;
    defer {
        for (functions.items) |*f| f.body.deinit(gpa);
        functions.deinit(gpa);
    }

    for (namespace.all()) |decl| {
        if (tree.nodeTag(decl.node) != .fn_decl) continue;
        const body = try Lower.run(&sema, decl);
        try functions.append(gpa, .{ .decl = decl, .body = body });
        try Region.run(gpa, &pool, tree, diagnostics, body);
    }

    // Emitting a program the checker rejected would only produce C that lies.
    if (emit) |w| {
        if (diagnostics.all().len == 0) {
            try codegen_c.emit(&pool, tree, &namespace, functions.items, w);
        }
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
