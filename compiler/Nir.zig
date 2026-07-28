//! Nul Intermediate Representation: a function body as a flat list of typed instructions.
//! `Lower` builds it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Comptime = @import("Comptime.zig");
const Namespace = @import("Namespace.zig");
const Type = @import("Type.zig");

const Nir = @This();

insts: []const Inst,
/// Variable-length operands: a call's arguments.
extra: []const u32,
/// The name bound to each instruction, `no_name` where there is none. Diagnostics name
/// values; the IR itself never reads this.
names: []const Ast.TokenIndex,

pub const no_name = std.math.maxInt(Ast.TokenIndex);

/// A lowered body and the declaration it came from, which is what a backend walks.
pub const Function = struct {
    decl: Namespace.Decl,
    body: Nir,
};

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
    /// Last token of that span, so a label underlines the whole expression.
    last: Ast.TokenIndex = 0,
    /// The type of the value produced, `.void` when there is none.
    ty: Type.Index,
    /// What is known about the value at compile time. Known values never materialize,
    /// a backend spells them at each use instead of binding them.
    val: Comptime.Value = .unknown,
    lhs: u32 = 0,
    rhs: u32 = 0,

    pub const Tag = enum(u8) {
        /// `lhs` is the parameter's position in the signature.
        arg,
        /// A value `val` knows entirely: a literal, or a reference that resolved to one.
        constant,
        str,
        /// A reference to a container declaration; `val` is its value when known.
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
        /// Takes no arena: `Arena.init()` is a builtin on the type.
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
    return if (token == no_name) null else token;
}

pub fn callArgs(nir: Nir, inst: Inst) []const u32 {
    const len = nir.extra[inst.rhs];
    return nir.extra[inst.rhs + 1 ..][0..len];
}
