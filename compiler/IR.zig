//! The typed IR, a control-flow graph per function.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Pool = @import("Pool.zig");

pub const ExtraIndex = enum(u32) { _ };

pub const Call = struct { callee: Pool.Instance, args: []const Ref };

pub const Func = struct {
    instance: Pool.Instance,
    insts: InstList.Slice,
    /// One `Ref` per word.
    extra: []const u32,
    /// Block zero is the entry, and every block is reachable.
    blocks: []const Block,

    pub const InstList = std.MultiArrayList(Inst);

    pub fn callAt(func: *const Func, at: ExtraIndex) Call {
        const start = @intFromEnum(at);
        assert(start + 2 <= func.extra.len);
        return .{
            .callee = @enumFromInt(func.extra[start]),
            .args = func.refsAt(start + 2, func.extra[start + 1]),
        };
    }

    /// Fields in declaration order.
    pub fn structInitAt(func: *const Func, at: ExtraIndex) []const Ref {
        const start = @intFromEnum(at);
        assert(start + 1 <= func.extra.len);
        return func.refsAt(start + 1, func.extra[start]);
    }

    fn refsAt(func: *const Func, start: u32, len: u32) []const Ref {
        assert(start + len <= func.extra.len);
        // a `Ref` is one `u32`
        return @ptrCast(func.extra[start..][0..len]);
    }

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
    /// `void_type` for an effect.
    type: Pool.Index,
    data: Data,

    pub const Index = enum(u32) {
        _,

        pub fn from(raw: usize) Index {
            assert(raw < std.math.maxInt(u32));
            return @enumFromInt(@as(u32, @intCast(raw)));
        }

        pub fn int(index: Index) u32 {
            return @intFromEnum(index);
        }
    };

    pub const Data = union {
        none: void,
        un: Ref,
        bin: struct { lhs: Ref, rhs: Ref },
        field: struct { base: Ref, row: u32 },
        probe: struct { operand: Ref, member: Pool.Index },
        name: Pool.String,
        payload: ExtraIndex,
    };

    pub const Tag = enum(u8) {
        /// Uses `name`. One per parameter, in order.
        param,
        /// Uses `name`, `.empty` for a temporary. Produces the address.
        local,
        /// Uses `un`, a place. Produces the pointee.
        load,
        /// Uses `bin`: the place, then the value.
        store,
        /// Uses `field`. Produces a field pointer, as mutable as its base.
        field_ptr,
        /// Uses `field`. Produces the field's value.
        field_val,

        // all `bin`
        add,
        sub,
        mul,
        div,
        mod,
        bit_and,
        bit_or,
        bit_xor,
        shift_left,
        /// Arithmetic, so a negative value keeps its sign.
        shift_right,
        cmp_eq,
        cmp_ne,
        cmp_lt,
        cmp_le,
        cmp_gt,
        cmp_ge,

        // all `un`
        negate,
        not,
        bit_not,

        /// Uses `un`. Retypes a pointer and emits nothing.
        ptr_cast,

        /// Uses `un`. A value entering a union that lists its type, or a
        /// narrower union widening. The tag stays the backend's.
        union_init,
        /// Uses `probe`. Whether the union holds that member, as a bool.
        union_is,
        /// Uses `un`. A union retyped to what a passed test proved: one
        /// member, or the rest of the union.
        union_narrow,

        /// Uses `payload`, an `IR.Call`.
        call,

        /// Uses `payload`, read by `structInitAt`.
        struct_init,
    };
};

pub const Block = struct {
    /// Instructions `first ..< end()`, contiguous.
    first: u32,
    count: u32,
    terminator: Terminator,

    pub fn end(block: Block) u32 {
        return block.first + block.count;
    }

    pub const Index = enum(u32) {
        entry = 0,
        _,

        pub fn from(raw: usize) Index {
            assert(raw < std.math.maxInt(u32));
            return @enumFromInt(@as(u32, @intCast(raw)));
        }

        pub fn int(index: Index) u32 {
            return @intFromEnum(index);
        }
    };
};

pub const Terminator = union(enum) {
    /// Still being built.
    none,
    jump: Block.Index,
    /// The condition is a union, and the then edge is taken when it holds
    /// its first member.
    branch: struct { cond: Ref, then_block: Block.Index, else_block: Block.Index },
    /// `.none` returns nothing.
    ret: Ref,
};

comptime {
    assert(@sizeOf(Inst.Tag) == 1);
    assert(@sizeOf(Ref) == 4);
    if (std.debug.runtime_safety == false) assert(@sizeOf(Inst.Data) == 8);
    assert(@sizeOf(Block) <= 24);
}
