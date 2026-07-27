//! ./zig-out/bin/nul example/hello.nul

const std = @import("std");
const Io = std.Io;

const Source = @import("Source.zig");
const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Namespace = @import("Namespace.zig");
const Sema = @import("Sema.zig");
const Type = @import("Type.zig");

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

    try w.writeAll("tokens\n");
    for (tree.tokens.items(.tag), tree.tokens.items(.start)) |tag, start| {
        const lc = try src.lineCol(gpa, start);
        try w.print("{d:>4}:{d:<3} {s}", .{ lc.line, lc.col, @tagName(tag) });
        const end = Tokenizer.tokenEnd(src.bytes, tag, start);
        if (tag == .semi and src.bytes[start] != ';') {
            try w.writeAll(" (inserted)");
        } else if (end > start) {
            try w.print(" '{f}'", .{std.zig.fmtString(src.bytes[start..end])});
        }
        try w.writeByte('\n');
    }

    try w.writeAll("\nnodes\n");
    try dumpNode(tree, w, .root, 0);

    if (tree.errors.len > 0) {
        try w.writeByte('\n');
        try Diagnostic.renderAll(gpa, tree.errors, tree, &src, w);
        return 1;
    }

    var pool = try InternPool.init(gpa);
    defer pool.deinit(gpa);

    var diagnostics: Diagnostic.List = .init(gpa);
    defer diagnostics.deinit();

    var namespace = try Namespace.collect(gpa, &tree, &diagnostics);
    defer namespace.deinit(gpa);

    var sema: Sema = .{
        .gpa = gpa,
        .pool = &pool,
        .tree = &tree,
        .namespace = &namespace,
        .diagnostics = &diagnostics,
    };
    defer sema.deinit();
    try sema.resolveDeclarations();

    try w.writeAll("\ndeclarations\n");
    for (namespace.all()) |decl| {
        try w.print("  {s} : ", .{tree.tokenSlice(decl.name_token)});
        // An unsettled import has no type to show, rather than the poison it holds.
        if (tree.nodeTag(decl.node) == .use_decl and decl.ty == .poisoned) {
            try w.writeAll("(unresolved import)\n");
            continue;
        }
        try Type.write(&pool, decl.ty, w);
        if (decl.ty == .type) {
            try w.writeAll(" = ");
            try Type.write(&pool, decl.value, w);
        }
        try w.writeByte('\n');
    }

    if (diagnostics.all().len == 0) return 0;

    try w.writeByte('\n');
    try Diagnostic.renderAll(gpa, diagnostics.all(), tree, &src, w);
    return 1;
}

fn dumpNode(tree: Ast, w: *Io.Writer, n: Ast.Node.Index, depth: u32) Io.Writer.Error!void {
    const node = tree.viewOf(n);
    const d = depth + 1;

    try w.splatByteAll(' ', depth * 2);
    try w.writeAll(@tagName(tree.nodeTag(n)));
    switch (node) {
        .ident, .number_literal, .str_literal => |tok| try w.print(" '{s}'", .{tree.tokenSlice(tok)}),
        .field_access => |f| try w.print(" '{s}'", .{tree.tokenSlice(f.name_token)}),
        .param, .field => |f| try w.print(" '{s}'", .{tree.tokenSlice(f.name_token)}),
        .fn_decl => |f| {
            try w.print(" '{s}'", .{tree.tokenSlice(f.name_token)});
            if (f.is_pub) try w.writeAll(" pub");
        },
        .var_decl => |v| {
            try w.print(" '{s}'", .{tree.tokenSlice(v.name_token)});
            if (v.is_pub) try w.writeAll(" pub");
        },
        .pointer_type => |ptr| if (ptr.is_mutable) try w.writeAll(" var"),
        .binary => |b| try w.print(" {s}", .{@tagName(b.op)}),
        .unary => |u| try w.print(" {s}", .{@tagName(u.op)}),
        .bool_literal => |b| try w.print(" {}", .{b.value}),
        else => {},
    }
    try w.writeByte('\n');

    switch (node) {
        .root, .block, .struct_type => |stmts| for (stmts) |c| try dumpNode(tree, w, c, d),
        .use_decl, .grouped => |child| try dumpNode(tree, w, child, d),
        .pointer_type => |ptr| try dumpNode(tree, w, ptr.child, d),
        .param, .field => |f| try dumpNode(tree, w, f.type_expr, d),
        .field_access => |f| try dumpNode(tree, w, f.lhs, d),
        .unary => |u| try dumpNode(tree, w, u.operand, d),
        .return_stmt => |e| if (e.unwrap()) |x| try dumpNode(tree, w, x, d),
        .assign => |a| {
            try dumpNode(tree, w, a.lhs, d);
            try dumpNode(tree, w, a.rhs, d);
        },
        .binary => |b| {
            try dumpNode(tree, w, b.lhs, d);
            try dumpNode(tree, w, b.rhs, d);
        },
        .call => |c| {
            try dumpNode(tree, w, c.callee, d);
            for (c.args) |a| try dumpNode(tree, w, a, d);
        },
        .fn_decl => |f| {
            for (f.params) |p| try dumpNode(tree, w, p, d);
            if (f.return_type.unwrap()) |rt| try dumpNode(tree, w, rt, d);
            try dumpNode(tree, w, f.body, d);
        },
        .var_decl => |v| {
            if (v.type_expr.unwrap()) |t| try dumpNode(tree, w, t, d);
            try dumpNode(tree, w, v.init_expr, d);
        },
        .ident, .number_literal, .str_literal, .bool_literal, .err => {},
    }
}
