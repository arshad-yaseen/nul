//! One function, lowered.
//!
//! Typed by construction: `Sema` checks an expression as it emits the instruction
//! for it, so a well formed `Ir` is already type correct and nothing downstream
//! re-checks types.
//!
//! Every instruction keeps the syntax node it came from, and every slot keeps its
//! name. That is not for debugging. `test/fail/01_store_scratch_in_arena.expected`
//! names two locals, the line their arena was created on, the store, and the escape,
//! and the region pass can only write that if the Ir remembers where things came
//! from. `Diagnostic` sorts labels by position, so instruction order never has to
//! match source order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const InternPool = @import("InternPool.zig");

const Ir = @This();

instructions: std.MultiArrayList(Inst).Slice,
/// Variable length operands, referenced by `Data.payload`.
extra: []const u32,
/// Basic blocks, each a contiguous run of `instructions`. There is exactly one until
/// the language grows control flow, and the region pass is written for many anyway.
blocks: []const Block,
slots: std.MultiArrayList(Slot).Slice,

pub fn deinit(ir: *Ir, gpa: Allocator) void {
    ir.instructions.deinit(gpa);
    ir.slots.deinit(gpa);
    gpa.free(ir.extra);
    gpa.free(ir.blocks);
    ir.* = undefined;
}

pub const Block = struct {
    start: u32,
    len: u32,
};

/// A `var` local. `let` binds a value directly and needs no memory, so it has no slot.
pub const Slot = struct {
    name: InternPool.String,
    /// What the slot holds, not the pointer to it.
    type: InternPool.Index,
    /// The `var` declaration, for a diagnostic that has to name where a value lives.
    node: Ast.Node.Index,

    pub const Index = enum(u32) { _ };
};

pub const Inst = struct {
    tag: Tag,
    /// The syntax that produced this. Never optional, every instruction can be blamed.
    node: Ast.Node.Index,
    /// The type of this instruction's result, `.type_void` when it has none.
    type: InternPool.Index,
    data: Data,

    /// An instruction index is also the name of the value it produces.
    pub const Index = enum(u32) {
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }
    };

    pub const Tag = enum(u8) {
        /// `data.value`, an interned constant. Types are values, so this carries them.
        constant,
        /// `data.index`, which parameter.
        arg,
        /// `data.slot`. The result is a pointer to the slot.
        slot,
        /// `data.un`, a pointer. The result is what it points at.
        load,
        /// `data.bin`, a pointer and the value to put in it.
        store,
        /// `data.field`. The result is a pointer to that field.
        field_ptr,
        /// `data.payload`, a `Call` followed by its arguments.
        call,

        add,
        sub,
        mul,
        div,
        mod,
        equal,
        not_equal,
        less_than,
        less_or_equal,
        greater_than,
        greater_or_equal,
        bool_and,
        bool_or,

        negate,
        bool_not,

        // The memory model's vocabulary. These exist as their own instructions
        // because the region pass has to see every one of them.

        /// `Arena.init()`, a region born and buried inside this function.
        arena_init,
        /// `data.un`, the parent arena.
        arena_child,
        /// `data.un`, the arena. `type` is the pointer it produced.
        arena_create,
        /// `data.bin`, the arena and the value copied into it.
        arena_copy,
        /// `data.un`, the arena being released.
        arena_reset,

        /// `data.opt_un`, the returned value if there is one.
        ret,

        pub fn isTerminator(tag: Tag) bool {
            return tag == .ret;
        }
    };

    /// Eight bytes reinterpreted by `tag`, the same contract as `Ast.Node.Data`.
    pub const Data = union {
        none: void,
        value: InternPool.Index,
        index: u32,
        slot: Slot.Index,
        un: Index,
        opt_un: OptionalIndex,
        bin: struct { Index, Index },
        field: struct { base: Index, index: u32 },
        payload: ExtraIndex,
    };
};

pub const ExtraIndex = enum(u32) { _ };

/// The head of a `call`'s payload, followed by `args_len` operands.
pub const Call = struct {
    /// Which function, as an index into the module's function table.
    callee: u32,
    args_len: u32,

    pub const len = 2;
};

comptime {
    assert(@sizeOf(Inst.Tag) == 1);
    if (!std.debug.runtime_safety) assert(@sizeOf(Inst.Data) == 8);
}

// Access

pub fn instTag(ir: Ir, i: Inst.Index) Inst.Tag {
    return ir.instructions.items(.tag)[@intFromEnum(i)];
}

pub fn typeOf(ir: Ir, i: Inst.Index) InternPool.Index {
    return ir.instructions.items(.type)[@intFromEnum(i)];
}

pub fn nodeOf(ir: Ir, i: Inst.Index) Ast.Node.Index {
    return ir.instructions.items(.node)[@intFromEnum(i)];
}

pub fn dataOf(ir: Ir, i: Inst.Index) Inst.Data {
    return ir.instructions.items(.data)[@intFromEnum(i)];
}

pub fn callArgs(ir: Ir, i: Inst.Index) []const Inst.Index {
    const at = @intFromEnum(ir.dataOf(i).payload);
    const len = ir.extra[at + 1];
    return @ptrCast(ir.extra[at + Call.len ..][0..len]);
}

pub fn callee(ir: Ir, i: Inst.Index) u32 {
    return ir.extra[@intFromEnum(ir.dataOf(i).payload)];
}
