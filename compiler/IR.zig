//! The typed IR, a control-flow graph per function.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Pool = @import("Pool.zig");

/// One checked body, owned by `Compilation.funcs`.
pub const Func = struct {
    instance: Pool.Instance,
    insts: InstList.Slice,
    /// Call and struct literal operands, one `Ref` per word.
    extra: []const u32,
    /// Block zero is the entry. Every block here is reachable.
    blocks: []const Block,

    pub const Index = enum(u32) {
        /// A bound primitive, with no body.
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

/// An instruction result or a pool constant, told apart by the top bit.
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
    /// `nothing_type` for an effect.
    type: Pool.Index,
    /// In the module being checked.
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
        /// `a` names it, `b` is its position. One per parameter, in order.
        param,
        /// Storage for a `var`, producing its address. `a` names it, `.empty`
        /// for a temporary the checker made.
        local,
        /// `a` is a place. Produces the pointee.
        load,
        /// `a` is a place, `b` the value.
        store,
        /// `a` is a struct pointer, `b` a row. Produces a field pointer, as
        /// mutable as its base.
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

        /// `a` points at `extra`: callee instance, count, argument refs.
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

        /// `a` points at `extra`: count, one ref per field in order.
        struct_init,

        /// Opens a scope. Its result names it, so the end hangs off one ref.
        scope_begin,
        /// `a` is the `scope_begin`. Emitted on every path out.
        scope_end,
    };
};

pub const Block = struct {
    /// Instructions `first ..< first + count`, contiguous.
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

pub const Terminator = union(enum) {
    /// Still being built. Gone by `finish`.
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
