//! The typed IR, a control-flow graph per function.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Pool = @import("Pool.zig");

/// One checked function body. Owned by the `funcs` table on the root object.
pub const Func = struct {
    /// The instantiation this body belongs to, which names it.
    instance: Pool.Instance,
    insts: InstList.Slice,
    /// Call arguments and struct literal operands, each a `Ref` word.
    extra: []const u32,
    /// Block zero is the entry. Every block here is reachable.
    blocks: []const Block,

    pub const Index = enum(u32) {
        /// A function whose body is not built, a bound primitive.
        none = std.math.maxInt(u32),
        _,
    };

    pub const InstList = std.MultiArrayList(Inst);

    pub fn deinit(func: *Func, gpa: Allocator) void {
        func.insts.deinit(gpa);
        gpa.free(func.extra);
        gpa.free(func.blocks);
        func.* = undefined;
    }
};

/// An operand, either an instruction's result or a constant from the pool.
/// One bit
/// tells them apart, so an operand is four bytes wherever it appears.
pub const Ref = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    const inst_bit: u32 = 1 << 31;

    pub fn fromConstant(value: Pool.Index) Ref {
        assert(value.int() < inst_bit);
        return @enumFromInt(value.int());
    }

    pub fn fromInst(inst: Inst.Index) Ref {
        assert(inst.int() < inst_bit - 1);
        return @enumFromInt(inst.int() | inst_bit);
    }

    pub fn unwrap(ref: Ref) union(enum) { constant: Pool.Index, inst: Inst.Index } {
        assert(ref != .none);
        const raw = @intFromEnum(ref);
        if (raw & inst_bit == 0) return .{ .constant = @enumFromInt(raw) };
        return .{ .inst = @enumFromInt(raw & ~inst_bit) };
    }
};

pub const Inst = struct {
    tag: Tag,
    /// What the instruction produces. Effects produce `nothing_type`.
    type: Pool.Index,
    /// Where it came from, in the module of the declaration being checked.
    node: AST.Node.Index,
    data: Data,

    pub const Index = enum(u32) {
        _,

        pub fn int(index: Index) u32 {
            return @intFromEnum(index);
        }
    };

    /// Two words whose meaning the tag decides.
    pub const Data = struct { a: u32, b: u32 };

    pub const Tag = enum(u8) {
        /// One per parameter, in order, at the head of the entry block.
        /// `a` names it, `b` is its position.
        param,
        /// Storage for a `var`. Its result is the slot's address, so its type
        /// is a pointer to the declared type. `a` names it, `.empty` for a
        /// temporary the checker made.
        local,
        /// `a` is a place. Produces the pointee.
        load,
        /// `a` is a place, `b` the value.
        store,
        /// `a` is a pointer to a struct, `b` a row in the instance's fields.
        /// Produces a pointer to the field, as mutable as its base.
        field_ptr,
        /// `a` is a struct value, `b` a row. Produces the field's value.
        field_val,

        add,
        sub,
        mul,
        div,
        mod,
        cmp_eq,
        cmp_ne,
        cmp_lt,
        cmp_le,
        cmp_gt,
        cmp_ge,
        negate,
        not,

        /// `a` points at `extra`, holding the callee instance, a count, then the
        /// argument refs. Extern and indirect callees are future callee kinds
        /// here, never new instructions.
        call,

        // the six primitives. `a` is the arena, `b` is `arena_copy`'s value.
        arena_init,
        arena_child,
        arena_create,
        arena_copy,
        arena_reset,
        arena_destroy,

        wrap_optional,
        has_value,
        unwrap_value,
        wrap_ok,
        wrap_err,
        is_error,
        unwrap_ok,
        unwrap_err,

        /// `a` points at `extra`, holding a count, then one ref per field in
        /// declaration order.
        struct_init,

        /// A scope opens. Its result names the scope, so the matching end and
        /// every arena death inside it hang off one ref.
        scope_begin,
        /// `a` is the `scope_begin`. Emitted on every path out.
        scope_end,
    };
};

pub const Block = struct {
    /// Instructions `first ..< first + count`, contiguous by construction.
    first: u32,
    count: u32,
    terminator: Terminator,

    pub const Index = enum(u32) {
        entry = 0,
        _,

        pub fn int(index: Index) u32 {
            return @intFromEnum(index);
        }
    };
};

/// How a block ends. `switch` and the bounds-check trap arrive as new cases
/// here, never as new mechanisms.
pub const Terminator = union(enum) {
    /// Still being built. Never survives `finish`.
    none,
    jump: Block.Index,
    branch: struct { cond: Ref, then_block: Block.Index, else_block: Block.Index },
    /// `.none` returns nothing.
    ret: Ref,
};

comptime {
    assert(@sizeOf(Inst.Tag) == 1);
    assert(@sizeOf(Ref) == 4);
    assert(@sizeOf(Inst.Data) == 8);
    assert(@sizeOf(Block) <= 24);
}
