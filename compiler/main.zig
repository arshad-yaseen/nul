//! ./zig-out/bin/nul example/hello.nul
//! ./zig-out/bin/nul --dump example/hello.nul

const std = @import("std");
const Io = std.Io;

const Source = @import("Source.zig");
const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Sema = @import("Sema.zig");
const Ir = @import("Ir.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    // Diagnostic strings are built here and released with the process, so nothing a
    // `Diagnostic` points at has to be owned individually.
    const arena = init.arena.allocator();

    var buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &buf);
    const w = &out_file.interface;
    defer w.flush() catch {};

    var dump = false;
    var path: ?[]const u8 = null;
    for ((try init.minimal.args.toSlice(arena))[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dump")) dump = true else path = arg;
    }
    if (path == null) {
        try w.writeAll("usage: nul [--dump] <file.nul>\n");
        return 1;
    }

    var src = Source.load(gpa, io, Io.Dir.cwd(), path.?) catch |e| {
        try w.print("nul: cannot read '{s}': {s}\n", .{ path.?, @errorName(e) });
        return 1;
    };
    defer src.deinit(gpa);

    var tree = try Ast.parse(gpa, src.bytes);
    defer tree.deinit(gpa);

    if (dump) try dumpTree(tree, &src, gpa, w);

    // Sema reads spans off a well formed tree, so a parse error stops things here.
    if (tree.errors.len > 0) {
        for (tree.errors) |err| {
            try w.writeByte('\n');

            // Every message the parser writes fits, they are built from fixed symbols.
            var msg_buf: [256]u8 = undefined;
            var msg: Io.Writer = .fixed(&msg_buf);
            try err.render(tree, &msg);

            const start = tree.tokenStart(err.token);
            const diag: Diagnostic = .{
                .message = msg.buffered(),
                .labels = &.{.{
                    .start = start,
                    .end = Tokenizer.tokenEnd(src.bytes, tree.tokenTag(err.token), start),
                    .style = .primary,
                }},
            };
            try diag.render(gpa, &src, w);
        }
        return 1;
    }

    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);

    var sema: Sema = .init(gpa, arena, tree, &ip);
    defer sema.deinit();
    try sema.analyze();

    if (dump) {
        try dumpSema(&sema, w);
        try dumpIr(&sema, w);
    }

    if (sema.diagnostics.items.len == 0) return 0;
    for (sema.diagnostics.items) |diag| {
        try w.writeByte('\n');
        try diag.render(gpa, &src, w);
    }
    return 1;
}

fn dumpTree(tree: Ast, src: *Source, gpa: std.mem.Allocator, w: *Io.Writer) !void {
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
}

/// Everything `Sema` learned, which is everything a later pass gets to rely on.
fn dumpSema(sema: *const Sema, w: *Io.Writer) Io.Writer.Error!void {
    const ip = sema.ip;
    const decls = sema.decls.slice();
    const params = sema.params.slice();

    // Types and values share one table, because a type is a value.
    try w.writeAll("\npool\n");
    for (InternPool.Index.static_count..ip.items.len) |raw| {
        const index: InternPool.Index = @enumFromInt(raw);
        try w.print("{d:>4}  ", .{raw});
        try dumpValue(ip, index, w);
        if (ip.keyOf(index) == .struct_type) {
            try w.writeAll(" = struct {");
            for (ip.structFields(index), 0..) |f, k| {
                try w.print("{s} {s}: ", .{ if (k > 0) "," else "", ip.stringSlice(f.name) });
                try ip.printType(f.type, w);
            }
            try w.writeAll(" }");
        }
        try w.writeByte('\n');
    }

    try w.writeAll("\ndecls\n");
    for (decls.items(.name), decls.items(.kind), decls.items(.value)) |name, kind, value| {
        try w.print("  {s:<10} {s}", .{ ip.stringSlice(name), @tagName(kind) });
        if (value.unwrap()) |v| try w.print("  value {d}", .{@intFromEnum(v)});
        try w.writeByte('\n');
    }

    try w.writeAll("\nsignatures\n");
    for (0..sema.fns.len) |i| {
        const f = sema.fns.get(i);
        try w.print("  {s}(", .{ip.stringSlice(decls.items(.name)[@intFromEnum(f.decl)])});
        for (0..f.params_len) |k| {
            const at = f.params_start + k;
            try w.print("{s}{s}: ", .{ if (k > 0) ", " else "", ip.stringSlice(params.items(.name)[at]) });
            try ip.printType(params.items(.type)[at], w);
        }
        try w.writeAll(") ");
        try ip.printType(f.return_type, w);
        if (f.arena_param != Sema.Fn.no_arena) {
            const name = params.items(.name)[f.params_start + f.arena_param];
            try w.print("   allocates into '{s}'", .{ip.stringSlice(name)});
        }
        try w.writeByte('\n');
    }
}

/// Every lowered body, one instruction per line. `%n` names an instruction and the
/// value it produced.
fn dumpIr(sema: *const Sema, w: *Io.Writer) Io.Writer.Error!void {
    const ip = sema.ip;
    const decls = sema.decls.slice();

    for (sema.bodies.items, 0..) |ir, fi| {
        const f = sema.fns.get(fi);
        try w.print("\nbody {s}\n", .{ip.stringSlice(decls.items(.name)[@intFromEnum(f.decl)])});

        for (0..ir.slots.len) |s| {
            const slot = ir.slots.get(s);
            try w.print("  slot {d} '{s}': ", .{ s, ip.stringSlice(slot.name) });
            try ip.printType(slot.type, w);
            try w.writeByte('\n');
        }

        for (0..ir.instructions.len) |raw| {
            const i: Ir.Inst.Index = @enumFromInt(raw);
            const tag = ir.instTag(i);
            const data = ir.dataOf(i);

            try w.print("  %{d:<3} {s:<13}", .{ raw, @tagName(tag) });
            switch (tag) {
                .constant => try dumpValue(ip, data.value, w),
                .arg => try w.print("#{d}", .{data.index}),
                .slot => try w.print("slot {d}", .{@intFromEnum(data.slot)}),
                .load, .negate, .bool_not, .arena_child, .arena_create, .arena_reset => {
                    try w.print("%{d}", .{@intFromEnum(data.un)});
                },
                .store, .arena_copy => try w.print("%{d} %{d}", .{
                    @intFromEnum(data.bin[0]),
                    @intFromEnum(data.bin[1]),
                }),
                .field_ptr => try w.print("%{d} field {d}", .{
                    @intFromEnum(data.field.base),
                    data.field.index,
                }),
                .call => {
                    const target = sema.fns.get(ir.callee(i));
                    try w.print("{s}", .{ip.stringSlice(decls.items(.name)[@intFromEnum(target.decl)])});
                    for (ir.callArgs(i)) |a| try w.print(" %{d}", .{@intFromEnum(a)});
                },
                .ret => if (data.opt_un.unwrap()) |v| try w.print("%{d}", .{@intFromEnum(v)}),
                .arena_init => {},
                else => try w.print("%{d} %{d}", .{
                    @intFromEnum(data.bin[0]),
                    @intFromEnum(data.bin[1]),
                }),
            }

            const ty = ir.typeOf(i);
            if (ty != .type_void and ty != .type_noreturn) {
                try w.writeAll("   : ");
                try ip.printType(ty, w);
            }
            try w.writeByte('\n');
        }
    }
}

fn dumpValue(ip: *const InternPool, v: InternPool.Index, w: *Io.Writer) Io.Writer.Error!void {
    switch (ip.keyOf(v)) {
        .int => |x| try w.print("{d}", .{x}),
        .str => |s| try w.print("\"{s}\"", .{ip.stringSlice(s)}),
        else => try ip.printType(v, w),
    }
}

fn dumpNode(tree: Ast, w: *Io.Writer, n: Ast.Node.Index, depth: u32) Io.Writer.Error!void {
    const node = tree.full(n);
    const d = depth + 1;

    try w.splatByteAll(' ', depth * 2);
    try w.writeAll(@tagName(tree.nodeTag(n)));
    switch (node) {
        .ident, .int_literal, .str_literal => |tok| try w.print(" '{s}'", .{tree.tokenSlice(tok)}),
        .field_access => |f| try w.print(" '{s}'", .{tree.tokenSlice(f.name_token)}),
        .param, .field => |f| try w.print(" '{s}'", .{tree.tokenSlice(f.name_token)}),
        .fn_decl => |f| try w.print(" '{s}'", .{tree.tokenSlice(f.name_token)}),
        .var_decl => |v| try w.print(" '{s}'", .{tree.tokenSlice(v.name_token)}),
        .pointer_type => |ptr| if (ptr.is_mutable) try w.writeAll(" var"),
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
        .ident, .int_literal, .str_literal, .bool_literal, .err => {},
    }
}
