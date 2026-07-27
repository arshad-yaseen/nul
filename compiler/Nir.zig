//! A function body as a flat list of typed instructions. `Lower` builds it.
//!
//! Built once per function, since a generic body is checked at its definition rather than
//! per instantiation. There is no control flow yet, so an instruction's position is its
//! execution order.
//!
//! Types live here; regions do not. The region checker keeps its own table alongside, so
//! no region is ever part of a type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ast = @import("Ast.zig");
const InternPool = @import("InternPool.zig");
const Type = @import("Type.zig");

const Nir = @This();

insts: []const Inst,
/// Variable-length operands: a call's arguments.
extra: []const u32,

pub const Index = enum(u32) { _ };

pub const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalIndex) ?Index {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }
};

/// A body is small, so this is a plain struct rather than the encoding `Ast` needs.
/// `lhs` and `rhs` are read according to `tag`.
pub const Inst = struct {
    tag: Tag,
    /// What a diagnostic about this instruction points at.
    token: Ast.TokenIndex,
    /// The type of the value produced, `.void` when there is none.
    ty: Type.Index,
    lhs: u32 = 0,
    rhs: u32 = 0,

    pub const Tag = enum(u8) {
        /// `lhs` is the parameter's position in the signature.
        arg,
        /// The value is not needed yet, only its type.
        int,
        float,
        str,
        bool,
        /// `rhs` is the interned value, when there is one.
        decl,
        /// `lhs` and `rhs` are operands, `token` is the operator.
        binary,
        /// `lhs` is the operand, `token` is the operator.
        unary,
        /// Loads field `rhs` of `lhs`.
        field,
        /// Stores `rhs` into the field named by the `field` instruction `lhs`.
        store_field,
        /// `lhs` is the callee, `rhs` locates `len` then that many arguments in `extra`.
        call,
        /// Takes no arena: `Arena.init()` is a builtin on the type.
        arena_init,
        /// `lhs` is the arena. `arena_create`'s type is already `*T`.
        arena_child,
        arena_create,
        /// `rhs` is the value copied.
        arena_copy,
        arena_reset,
        arena_destroy,
        /// `lhs` is the returned value, or `none`.
        ret,
        /// Reported already, or not lowered yet. Nothing downstream should trust it.
        todo,
    };
};

pub fn deinit(nir: *Nir, gpa: Allocator) void {
    gpa.free(nir.insts);
    gpa.free(nir.extra);
    nir.* = undefined;
}

pub fn callArgs(nir: Nir, inst: Inst) []const u32 {
    const len = nir.extra[inst.rhs];
    return nir.extra[inst.rhs + 1 ..][0..len];
}

/// One line per instruction, for the dump.
pub fn write(nir: Nir, pool: *const InternPool, tree: Ast, w: *Io.Writer) Io.Writer.Error!void {
    for (nir.insts, 0..) |inst, at| {
        try w.print("    %{d:<3} {s}", .{ at, @tagName(inst.tag) });
        switch (inst.tag) {
            .arg => try w.print(" {d}", .{inst.lhs}),
            .decl => try w.print(" '{s}'", .{tree.tokenSlice(inst.token)}),
            .int, .float, .str, .bool => try w.print(" '{s}'", .{tree.tokenSlice(inst.token)}),
            .binary, .unary => try w.print(" {s} %{d}", .{ tree.tokenSlice(inst.token), inst.lhs }),
            .field => try w.print(" %{d}.{d}", .{ inst.lhs, inst.rhs }),
            .store_field, .arena_copy => try w.print(" %{d} %{d}", .{ inst.lhs, inst.rhs }),
            .arena_child, .arena_create, .arena_reset, .arena_destroy => {
                try w.print(" %{d}", .{inst.lhs});
            },
            .call => {
                try w.print(" %{d}(", .{inst.lhs});
                for (nir.callArgs(inst), 0..) |arg, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("%{d}", .{arg});
                }
                try w.writeByte(')');
            },
            .ret => if (@as(OptionalIndex, @enumFromInt(inst.lhs)).unwrap()) |v| {
                try w.print(" %{d}", .{@intFromEnum(v)});
            },
            .arena_init, .todo => {},
        }
        if (inst.ty != .void) {
            try w.writeAll(" : ");
            try Type.write(pool, inst.ty, w);
        }
        try w.writeByte('\n');
    }
}
