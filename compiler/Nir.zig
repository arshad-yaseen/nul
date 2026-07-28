//! Nul Intermediate Representation. A function body as a flat list of typed
//! instructions, built by `Lower`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Namespace = @import("Namespace.zig");
const Value = @import("Value.zig");

const Nir = @This();

insts: []const Inst,
/// A call's arguments, which do not fit in two slots.
extra: []const u32,
/// The name bound to each instruction, `none` where there is none. Only diagnostics
/// read this.
names: []const Ast.TokenIndex,

/// An absent operand or name.
pub const none = std.math.maxInt(u32);

pub const Function = struct {
    decl: Namespace.Decl,
    body: Nir,
};

/// `lhs` and `rhs` are untyped slots, and `View` is what reads them.
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
        arg,
        constant,
        str,
        decl,
        binary,
        unary,
        /// A `var` passes through here to shed comptime knownness.
        coerce,
        field,
        store_field,
        call,
        arena_init,
        arena_child,
        arena_create,
        arena_copy,
        arena_reset,
        arena_destroy,
        /// The scope that made this arena ended. Not a release, since nothing can name
        /// it past here.
        arena_end,
        ret,
        /// Reported already, or not lowered yet. Nothing downstream should trust it.
        todo,
    };
};

/// An instruction widened into named fields. The only code that reads `lhs` and `rhs`,
/// so the encoding changes in one place rather than at every use.
pub const View = union(enum) {
    parameter: Parameter,
    /// `val` holds everything these are.
    constant,
    str,
    decl,
    binary: Pair,
    unary: Operand,
    coerce: Operand,
    field: Field,
    store_field: Store,
    call: Call,
    arena_init,
    arena_child: Child,
    arena_create: Allocation,
    arena_copy: Copy,
    arena_reset: Allocation,
    arena_destroy: Allocation,
    arena_end: Allocation,
    returned: Returned,
    todo,

    /// Where the parameter sits in the signature. Not an instruction.
    pub const Parameter = struct { position: u32 };
    pub const Pair = struct { lhs: u32, rhs: u32 };
    pub const Operand = struct { operand: u32 };
    pub const Field = struct { base: u32, position: u32 };
    pub const Store = struct { place: u32, value: u32 };
    pub const Call = struct { callee: u32, args: []const u32 };
    pub const Child = struct { parent: u32 };
    pub const Allocation = struct { arena: u32 };
    pub const Copy = struct { arena: u32, value: u32 };
    /// Null for a bare `return`.
    pub const Returned = struct { value: ?u32 };
};

pub fn viewOf(nir: Nir, inst: Inst) View {
    return switch (inst.tag) {
        .arg => .{ .parameter = .{ .position = inst.lhs } },
        .constant => .constant,
        .str => .str,
        .decl => .decl,
        .binary => .{ .binary = .{ .lhs = inst.lhs, .rhs = inst.rhs } },
        .unary => .{ .unary = .{ .operand = inst.lhs } },
        .coerce => .{ .coerce = .{ .operand = inst.lhs } },
        .field => .{ .field = .{ .base = inst.lhs, .position = inst.rhs } },
        .store_field => .{ .store_field = .{ .place = inst.lhs, .value = inst.rhs } },
        .call => .{ .call = .{ .callee = inst.lhs, .args = nir.callArgs(inst) } },
        .arena_init => .arena_init,
        .arena_child => .{ .arena_child = .{ .parent = inst.lhs } },
        .arena_create => .{ .arena_create = .{ .arena = inst.lhs } },
        .arena_copy => .{ .arena_copy = .{ .arena = inst.lhs, .value = inst.rhs } },
        .arena_reset => .{ .arena_reset = .{ .arena = inst.lhs } },
        .arena_destroy => .{ .arena_destroy = .{ .arena = inst.lhs } },
        .arena_end => .{ .arena_end = .{ .arena = inst.lhs } },
        .ret => .{ .returned = .{ .value = if (inst.lhs == none) null else inst.lhs } },
        .todo => .todo,
    };
}

/// Every instruction this one reads, so a checker walks values rather than slots. Two
/// is the most any fixed-arity instruction has, and a call already has its own array.
pub fn operandsOf(nir: Nir, inst: Inst, buf: *[2]u32) []const u32 {
    switch (nir.viewOf(inst)) {
        .binary => |it| buf.* = .{ it.lhs, it.rhs },
        .store_field => |it| buf.* = .{ it.place, it.value },
        .arena_copy => |it| buf.* = .{ it.arena, it.value },
        .unary, .coerce => |it| return one(buf, it.operand),
        .field => |it| return one(buf, it.base),
        .arena_child => |it| return one(buf, it.parent),
        .arena_create, .arena_reset, .arena_destroy, .arena_end => |it| return one(buf, it.arena),
        .returned => |it| return one(buf, it.value orelse return buf[0..0]),
        .call => |it| return it.args,
        .parameter, .constant, .str, .decl, .arena_init, .todo => return buf[0..0],
    }
    return buf[0..2];
}

fn one(buf: *[2]u32, operand: u32) []const u32 {
    buf[0] = operand;
    return buf[0..1];
}

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

fn callArgs(nir: Nir, inst: Inst) []const u32 {
    const len = nir.extra[inst.rhs];
    return nir.extra[inst.rhs + 1 ..][0..len];
}
