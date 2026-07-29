//! Nul Intermediate Representation. A function body as a control flow graph:
//! typed instructions in one flat list, blocks each closed by one terminator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const Namespace = @import("Namespace.zig");
const Value = @import("Value.zig");

const Nir = @This();

/// Every instruction in the function, flat. A `Ref` is a position here, and a block is
/// a contiguous run of them.
insts: []const Inst,
/// Every block. A `Block.Ref` is a position here, and block 0 is the entry.
blocks: []const Block,
/// Argument lists, referenced by `Range`.
extra: []const Ref,

/// One lowered body, kept beside the declaration it came from.
pub const Function = struct {
    /// Where the name and signature are, since neither is repeated here.
    decl: Namespace.Index,
    body: Nir,
};

/// An instruction, by position in `insts`. Operands are these rather than values, so an
/// instruction names what produced its input instead of holding a copy.
pub const Ref = enum(u32) {
    _,

    /// The plain index, for a pass keeping side tables.
    pub fn i(ref: Ref) u32 {
        return @intFromEnum(ref);
    }
};

/// A run of `Ref`s in `extra`.
pub const Range = struct { start: u32, len: u32 };

/// What `Inst.name` holds when no local was bound to the value.
const no_name = std.math.maxInt(u32);

pub const Inst = struct {
    /// Which instruction this is, and what it reads.
    data: Data,
    /// What this yields, `.void` when nothing. A known value never materializes, since
    /// a backend spells it at each use instead of binding it.
    val: Value,
    /// What a diagnostic about this instruction points at.
    token: Ast.TokenIndex,
    /// Last token of that span, or zero when the span is one token wide.
    last: Ast.TokenIndex = 0,
    /// The local bound to this value, when a name was. Only diagnostics read it.
    name: Ast.TokenIndex = no_name,
};

/// A single-`Ref` payload is that operand; a struct payload names each part.
pub const Data = union(enum) {
    /// Position in the signature.
    arg: u32,
    /// `val` holds everything these are.
    constant,
    str,
    decl,
    /// A mutable local. `val` is a mutable pointer to the slot's frame memory.
    alloc,
    /// The pointer read through: a slot, a `field_ptr`, or any pointer value.
    load: Ref,
    /// The pointer written through, which has to be mutable.
    store: Store,
    /// The operator is read back off `token`, so no opcode is stored here.
    binary: Binary,
    unary: Ref,
    /// A binding takes its declared type here, and a `var` sheds comptime knownness.
    coerce: Ref,
    /// A field extracted from a struct value. No memory is involved.
    field_val: Field,
    /// A pointer to a field of what `base` points at.
    field_ptr: Field,
    call: Call,
    arena_init,
    /// The parent arena.
    arena_child: Ref,
    /// The arena allocated from.
    arena_create: Ref,
    arena_copy: Copy,
    arena_reset: Ref,
    arena_destroy: Ref,
    /// The scope that made this arena ended. Not a release: nothing can name it past here.
    arena_end: Ref,
    /// Reported already, or not lowered yet. Nothing downstream should trust it.
    todo,

    pub const Store = struct { ptr: Ref, value: Ref };
    pub const Binary = struct { lhs: Ref, rhs: Ref };
    /// `index` is the field's position in the owning struct, never its name.
    pub const Field = struct { base: Ref, index: u32 };
    pub const Call = struct { callee: Ref, args: Range };
    pub const Copy = struct { arena: Ref, value: Ref };
};

/// A contiguous run of instructions, `[first..end())`, closed by one terminator.
pub const Block = struct {
    /// Where the run starts in `insts`.
    first: u32,
    count: u32,
    term: Term,

    /// A block, by position in `blocks`.
    pub const Ref = enum(u32) { entry = 0, _ };

    pub fn end(b: Block) u32 {
        return b.first + b.count;
    }
};

/// How a block ends, and so where control goes next.
pub const Term = union(enum) {
    jump: Block.Ref,
    branch: Branch,
    ret: Return,

    /// Both targets are real blocks. An `if` with no `else` points `els` at the join.
    pub const Branch = struct { cond: Ref, then: Block.Ref, els: Block.Ref };
    /// Carries a span because returning is where escaping a region is blamed.
    pub const Return = struct { value: ?Ref, token: Ast.TokenIndex, last: Ast.TokenIndex };
};

// Queries

pub fn get(nir: Nir, ref: Ref) Inst {
    return nir.insts[ref.i()];
}

pub fn refs(nir: Nir, range: Range) []const Ref {
    return nir.extra[range.start..][0..range.len];
}

pub fn nameOf(nir: Nir, ref: Ref) ?Ast.TokenIndex {
    const token = nir.get(ref).name;
    return if (token == no_name) null else token;
}

pub fn successorsOf(term: Term, buf: *[2]Block.Ref) []const Block.Ref {
    switch (term) {
        .ret => return buf[0..0],
        .jump => |target| {
            buf[0] = target;
            return buf[0..1];
        },
        .branch => |it| {
            buf.* = .{ it.then, it.els };
            return buf[0..2];
        },
    }
}

/// `Lower` keeps lowering after a `return` so dead statements still type check,
/// but no pass should judge them.
pub fn reachableBlocks(gpa: Allocator, blocks: []const Block) Allocator.Error![]bool {
    const seen = try gpa.alloc(bool, blocks.len);
    @memset(seen, false);
    if (blocks.len == 0) return seen;

    var work: std.ArrayList(Block.Ref) = .empty;
    defer work.deinit(gpa);
    try work.append(gpa, .entry);
    seen[0] = true;

    while (work.pop()) |at| {
        var buf: [2]Block.Ref = undefined;
        for (successorsOf(blocks[@intFromEnum(at)].term, &buf)) |next| {
            if (seen[@intFromEnum(next)]) continue;
            seen[@intFromEnum(next)] = true;
            try work.append(gpa, next);
        }
    }
    return seen;
}

pub fn deinit(nir: *Nir, gpa: Allocator) void {
    gpa.free(nir.insts);
    gpa.free(nir.blocks);
    gpa.free(nir.extra);
    nir.* = undefined;
}

// Construction

pub const Builder = struct {
    gpa: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    blocks: std.ArrayList(Wip) = .empty,
    extra: std.ArrayList(Ref) = .empty,
    /// The block instructions are appended to, meaningful only while `open`.
    current: Block.Ref = .entry,
    /// Whether a block is taking instructions. Sealing closes it, activating opens one.
    open: bool = false,

    /// A block while it builds. `term` arrives when it seals.
    const Wip = struct { first: u32 = 0, count: u32 = 0, term: ?Term = null };

    pub fn deinit(b: *Builder) void {
        b.insts.deinit(b.gpa);
        b.blocks.deinit(b.gpa);
        b.extra.deinit(b.gpa);
        b.* = undefined;
    }

    /// Mints a block whose instructions arrive later, so terminators seal with real targets.
    pub fn reserve(b: *Builder) Allocator.Error!Block.Ref {
        const at: Block.Ref = @enumFromInt(b.blocks.items.len);
        try b.blocks.append(b.gpa, .{});
        return at;
    }

    /// Only one block is ever open, which is what keeps its instructions contiguous.
    pub fn activate(b: *Builder, at: Block.Ref) void {
        assert(!b.open);
        b.blocks.items[@intFromEnum(at)].first = @intCast(b.insts.items.len);
        b.current = at;
        b.open = true;
    }

    /// Opens a block nothing jumps to, so statements after a `return` still lower.
    pub fn ensureOpen(b: *Builder) Allocator.Error!void {
        if (!b.open) b.activate(try b.reserve());
    }

    pub fn seal(b: *Builder, term: Term) void {
        assert(b.open);
        const wip = &b.blocks.items[@intFromEnum(b.current)];
        wip.count = @as(u32, @intCast(b.insts.items.len)) - wip.first;
        wip.term = term;
        b.open = false;
    }

    pub fn sealJump(b: *Builder, target: Block.Ref) void {
        b.seal(.{ .jump = target });
    }

    pub fn add(b: *Builder, inst: Inst) Allocator.Error!Ref {
        assert(b.open);
        try b.insts.append(b.gpa, inst);
        return @enumFromInt(b.insts.items.len - 1);
    }

    /// Commits an argument list in one piece, since evaluating an argument may add
    /// lists of its own in between.
    pub fn argRange(b: *Builder, args: []const Ref) Allocator.Error!Range {
        const start: u32 = @intCast(b.extra.items.len);
        try b.extra.appendSlice(b.gpa, args);
        return .{ .start = start, .len = @intCast(args.len) };
    }

    pub fn valOf(b: *const Builder, ref: Ref) Value {
        return b.insts.items[ref.i()].val;
    }

    pub fn dataOf(b: *const Builder, ref: Ref) Data {
        return b.insts.items[ref.i()].data;
    }

    pub fn setName(b: *Builder, ref: Ref, token: Ast.TokenIndex) void {
        b.insts.items[ref.i()].name = token;
    }

    /// Whether control reaches `target`, an open block counted as going nowhere yet.
    pub fn reaches(b: *const Builder, target: Block.Ref) Allocator.Error!bool {
        const seen = try b.gpa.alloc(bool, b.blocks.items.len);
        defer b.gpa.free(seen);
        @memset(seen, false);
        var work: std.ArrayList(Block.Ref) = .empty;
        defer work.deinit(b.gpa);

        try work.append(b.gpa, .entry);
        seen[0] = true;
        while (work.pop()) |at| {
            if (at == target) return true;
            const term = b.blocks.items[@intFromEnum(at)].term orelse continue;
            var buf: [2]Block.Ref = undefined;
            for (successorsOf(term, &buf)) |next| {
                if (seen[@intFromEnum(next)]) continue;
                seen[@intFromEnum(next)] = true;
                try work.append(b.gpa, next);
            }
        }
        return false;
    }

    /// Hands the graph over. Every block is sealed by now, asserted rather than trusted.
    pub fn finish(b: *Builder) Allocator.Error!Nir {
        const blocks = try b.gpa.alloc(Block, b.blocks.items.len);
        errdefer b.gpa.free(blocks);
        for (b.blocks.items, blocks) |wip, *blk| {
            blk.* = .{ .first = wip.first, .count = wip.count, .term = wip.term.? };
        }
        b.blocks.deinit(b.gpa);
        b.blocks = .empty;
        return .{
            .insts = try b.insts.toOwnedSlice(b.gpa),
            .blocks = blocks,
            .extra = try b.extra.toOwnedSlice(b.gpa),
        };
    }
};
