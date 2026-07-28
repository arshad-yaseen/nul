//! Nul Intermediate Representation. A function body as a flat list of typed
//! instructions, built by `Lower`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Namespace = @import("Namespace.zig");
const Value = @import("Value.zig");

const Nir = @This();

insts: []const Inst,
/// Variable-length operands, meaning a call's arguments.
extra: []const u32,
/// The name bound to each instruction, `none` where there is none. Only diagnostics
/// read this.
names: []const Ast.TokenIndex,

/// Marks an absent operand or name.
pub const none = std.math.maxInt(u32);

/// A lowered body and the declaration it came from, which is what a backend walks.
pub const Function = struct {
    decl: Namespace.Decl,
    body: Nir,
};

/// A body is small, so this is a plain struct rather than the encoding `Ast` needs.
/// `lhs` and `rhs` are read according to `tag`.
pub const Inst = struct {
    tag: Tag,
    /// What a diagnostic about this instruction points at.
    token: Ast.TokenIndex,
    /// Last token of that span, so a label underlines the whole expression.
    last: Ast.TokenIndex = 0,
    /// What this instruction yields, type `.void` when nothing. A known value never
    /// materializes, since a backend spells it at each use instead of binding it.
    val: Value,
    lhs: u32 = 0,
    rhs: u32 = 0,

    pub const Tag = enum(u8) {
        /// `lhs` is the parameter's position in the signature.
        arg,
        /// A value `val` knows entirely, meaning a literal or a name that reached one.
        constant,
        str,
        /// A reference to a container declaration, carrying its value when known.
        decl,
        /// `lhs` and `rhs` are operands, `token` is the operator.
        binary,
        /// `lhs` is the operand, `token` is the operator.
        unary,
        /// Retypes `lhs`, which is what a type annotation does. A `var` also passes
        /// through here to shed comptime knownness, since a mutable slot is runtime.
        coerce,
        /// Loads field `rhs` of `lhs`.
        field,
        /// Stores `rhs` into the field named by the `field` instruction `lhs`.
        store_field,
        /// `lhs` is the callee, `rhs` locates `len` then that many arguments in `extra`.
        call,
        /// Takes no arena, since `Arena.init()` is a builtin on the type.
        arena_init,
        /// `lhs` is the arena. `arena_create`'s type is already `*T`.
        arena_child,
        arena_create,
        /// `rhs` is the value copied.
        arena_copy,
        arena_reset,
        arena_destroy,
        /// The scope that made this arena ended. Not a release, nothing can name the
        /// arena past here, so a checker has nothing to prove and a backend frees.
        arena_end,
        /// `lhs` is the returned value, or `none`.
        ret,
        /// Reported already, or not lowered yet. Nothing downstream should trust it.
        todo,
    };
};

pub fn deinit(nir: *Nir, gpa: Allocator) void {
    gpa.free(nir.insts);
    gpa.free(nir.extra);
    gpa.free(nir.names);
    nir.* = undefined;
}

/// `last` defaults to `token`, since most instructions are one token wide.
pub fn spanOf(nir: Nir, inst: u32) struct { Ast.TokenIndex, Ast.TokenIndex } {
    const it = nir.insts[inst];
    return .{ it.token, if (it.last == 0) it.token else it.last };
}

pub fn nameOf(nir: Nir, inst: u32) ?Ast.TokenIndex {
    const token = nir.names[inst];
    return if (token == none) null else token;
}

/// The value a `ret` returns, when it returns one.
pub fn retOperand(inst: Inst) ?u32 {
    return if (inst.lhs == none) null else inst.lhs;
}

pub fn callArgs(nir: Nir, inst: Inst) []const u32 {
    const len = nir.extra[inst.rhs];
    return nir.extra[inst.rhs + 1 ..][0..len];
}
