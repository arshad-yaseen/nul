//! Prints `Nir` as text, what `check` judged, and what a checker or backend will
//! consume. The inspection window into the compiler.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ast = @import("Ast.zig");
const Namespace = @import("Namespace.zig");
const Nir = @import("Nir.zig");
const Type = @import("Type.zig");

pub const Error = Allocator.Error || Io.Writer.Error;

pub fn write(
    gpa: Allocator,
    types: *const Type,
    tree: *const Ast,
    ns: *Namespace,
    functions: []const Nir.Function,
    w: *Io.Writer,
) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (functions, 0..) |f, at| {
        if (at > 0) try w.writeByte('\n');
        try function(arena, types, tree, ns, f, w);
    }
}

fn function(
    arena: Allocator,
    types: *const Type,
    tree: *const Ast,
    ns: *Namespace,
    f: Nir.Function,
    w: *Io.Writer,
) Error!void {
    const decl = ns.decl(f.decl);
    try w.print("fn {s}: {s}\n", .{
        tree.tokenSlice(decl.name_token),
        try types.spell(decl.value.ty, arena),
    });

    const nir = f.body;
    const reach = try Nir.reachableBlocks(arena, nir.blocks);
    for (nir.blocks, 0..) |blk, b| {
        try w.print("b{d}:{s}\n", .{ b, if (reach[b]) "" else " unreachable" });
        for (blk.first..blk.end()) |i| {
            try instruction(arena, types, tree, ns, nir, @intCast(i), w);
        }
        try terminator(blk.term, w);
    }
}

fn instruction(
    arena: Allocator,
    types: *const Type,
    tree: *const Ast,
    ns: *Namespace,
    nir: Nir,
    at: u32,
    w: *Io.Writer,
) Error!void {
    const inst = nir.insts[at];
    try w.print("  %{d} = ", .{at});

    switch (inst.data) {
        .arg => |position| try w.print("arg {d}", .{position}),
        .constant => try w.writeAll("constant"),
        .str => try w.print("str {s}", .{tree.tokenSlice(inst.token)}),
        .decl => try w.print("decl {s}", .{tree.tokenSlice(inst.token)}),
        .alloc => try w.writeAll("alloc"),
        .load => |slot| try w.print("load %{d}", .{slot.i()}),
        .store => |it| try w.print("store %{d}, %{d}", .{ it.slot.i(), it.value.i() }),
        .binary => |it| try w.print("binary({s}) %{d}, %{d}", .{
            tree.tokenSlice(inst.token), it.lhs.i(), it.rhs.i(),
        }),
        .unary => |operand| try w.print("unary({s}) %{d}", .{
            tree.tokenSlice(inst.token), operand.i(),
        }),
        .coerce => |operand| try w.print("coerce %{d}", .{operand.i()}),
        .field => |it| try w.print("field %{d}.{s}", .{
            it.base.i(), tree.tokenSlice(inst.last),
        }),
        .store_field => |it| try w.print("store_field %{d}, %{d}", .{
            it.place.i(), it.value.i(),
        }),
        .call => |it| {
            switch (nir.get(it.callee).val.known) {
                .func => |index| try w.print("call {s}(", .{
                    tree.tokenSlice(ns.decl(index).name_token),
                }),
                else => try w.print("call %{d}(", .{it.callee.i()}),
            }
            for (nir.refs(it.args), 0..) |ref, position| {
                if (position > 0) try w.writeAll(", ");
                try w.print("%{d}", .{ref.i()});
            }
            try w.writeByte(')');
        },
        .arena_init => try w.writeAll("arena_init"),
        .arena_child => |parent| try w.print("arena_child %{d}", .{parent.i()}),
        .arena_create => |a| try w.print("arena_create %{d}", .{a.i()}),
        .arena_copy => |it| try w.print("arena_copy %{d}, %{d}", .{ it.arena.i(), it.value.i() }),
        .arena_reset => |a| try w.print("arena_reset %{d}", .{a.i()}),
        .arena_destroy => |a| try w.print("arena_destroy %{d}", .{a.i()}),
        .arena_end => |a| try w.print("arena_end %{d}", .{a.i()}),
        .todo => try w.writeAll("todo"),
    }

    if (inst.val.ty != .void) try w.print(" : {s}", .{try types.spell(inst.val.ty, arena)});
    switch (inst.val.known) {
        .runtime => {},
        .int => |x| try w.print(" = {d}", .{x}),
        .float => |x| try w.print(" = {d}", .{x}),
        .bool => |x| try w.print(" = {}", .{x}),
        .type => |ty| try w.print(" = {s}", .{try types.spell(ty, arena)}),
        .func => |index| try w.print(" = {s}", .{tree.tokenSlice(ns.decl(index).name_token)}),
    }
    if (nir.nameOf(@enumFromInt(at))) |token| {
        try w.print("  ; {s}", .{tree.tokenSlice(token)});
    }
    try w.writeByte('\n');
}

fn terminator(term: Nir.Term, w: *Io.Writer) Io.Writer.Error!void {
    switch (term) {
        .jump => |target| try w.print("  jump b{d}\n", .{@intFromEnum(target)}),
        .branch => |it| try w.print("  branch %{d}, b{d}, b{d}\n", .{
            it.cond.i(), @intFromEnum(it.then), @intFromEnum(it.els),
        }),
        .ret => |r| if (r.value) |value| {
            try w.print("  ret %{d}\n", .{value.i()});
        } else {
            try w.writeAll("  ret\n");
        },
    }
}
