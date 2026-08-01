//! The typed IR, a control-flow graph per function.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Pool = @import("Pool.zig");

/// `Func.extra`.
pub const ExtraIndex = enum(u32) { _ };

/// Who a `call` reaches.
pub const Callee = enum(u32) {
    _,

    const foreign_bit: u32 = 1 << 31;

    pub fn fromInstance(index: Pool.Instance) Callee {
        assert(index.int() < foreign_bit);
        return @enumFromInt(index.int());
    }

    pub fn unwrap(callee: Callee) union(enum) { instance: Pool.Instance } {
        const raw = @intFromEnum(callee);
        assert(raw & foreign_bit == 0);
        return .{ .instance = @enumFromInt(raw) };
    }
};

/// A `call` payload, read back.
pub const Call = struct { callee: Callee, args: []const Ref };

/// One checked body, owned by `Compilation.funcs`.
pub const Func = struct {
    instance: Pool.Instance,
    insts: InstList.Slice,
    /// Call and struct literal operands, one `Ref` per word.
    extra: []const u32,
    /// Block zero is the entry. Every block here is reachable.
    blocks: []const Block,

    pub const InstList = std.MultiArrayList(Inst);

    /// A call's callee and its arguments.
    pub fn callAt(func: *const Func, at: ExtraIndex) Call {
        const start = @intFromEnum(at);
        assert(start + 2 <= func.extra.len);
        return .{
            .callee = @enumFromInt(func.extra[start]),
            .args = func.refsAt(start + 2, func.extra[start + 1]),
        };
    }

    /// A struct literal's fields, in declaration order.
    pub fn structInitAt(func: *const Func, at: ExtraIndex) []const Ref {
        const start = @intFromEnum(at);
        assert(start + 1 <= func.extra.len);
        return func.refsAt(start + 1, func.extra[start]);
    }

    fn refsAt(func: *const Func, start: u32, len: u32) []const Ref {
        assert(start + len <= func.extra.len);
        // a `Ref` is one `u32`, asserted below
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

    pub const Data = union {
        none: void,
        un: Ref,
        bin: struct { lhs: Ref, rhs: Ref },
        field: struct { base: Ref, row: u32 },
        name: Pool.String,
        param: struct { name: Pool.String, position: u32 },
        payload: ExtraIndex,
    };

    pub const Tag = enum(u8) {
        /// Uses `param`. One per parameter, in order.
        param,
        /// Storage for a `var`, producing its address. Uses `name`, `.empty`
        /// for a temporary the checker made.
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
        cmp_eq,
        cmp_ne,
        cmp_lt,
        cmp_le,
        cmp_gt,
        cmp_ge,

        // both `un`
        negate,
        not,

        /// Uses `payload`, an `IR.Call`.
        call,

        // the six primitives. `un` is the arena, `arena_copy` uses `bin` for
        // the arena and the value, `arena_init` uses `none`
        arena_init,
        arena_child,
        arena_create,
        arena_copy,
        arena_reset,
        arena_destroy,

        // all `un`
        wrap_optional,
        has_value,
        unwrap_value,
        wrap_ok,
        wrap_err,
        is_error,
        unwrap_ok,
        unwrap_err,

        /// Uses `payload`, an `IR.StructInit`.
        struct_init,

        /// Uses `none`. Its result names the scope, so the end hangs off it.
        scope_begin,
        /// Uses `un`, the `scope_begin`. Emitted on every path out.
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
    assert(@sizeOf(Callee) == 4);
    if (std.debug.runtime_safety == false) assert(@sizeOf(Inst.Data) == 8);
    assert(@sizeOf(Block) <= 24);
}
