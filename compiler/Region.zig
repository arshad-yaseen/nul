//! Proves the memory model over one function body.
//!
//! > Every pointer reachable from a value in some arena points into an arena that
//! > outlives it.
//!
//! So the whole check is that a value may only be stored into memory it outlives.
//! Regions form a tree, since `child` is the only way to make one, and "outlives"
//! is an ancestor walk. Nothing here crosses a function boundary.
//!
//! What a slot holds is a forward dataflow: a join merges toward whichever region
//! dies first, and two incomparable ones merge into a `merged` region answering for
//! both. A release is judged per path, with the value's origin as the barrier a
//! path repasses to remake it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Nir = @import("Nir.zig");
const Type = @import("Type.zig");

const Region = @This();
const Token = Ast.TokenIndex;
const Ref = Nir.Ref;

gpa: Allocator,
types: *const Type,
tree: *const Ast,
diagnostics: *Diagnostic.List,
nir: Nir,
/// The region each value lives in.
of: []Index,
/// The instruction that made each value.
origin: []Origin,
block_of: []u32,
/// Only reachable blocks are judged.
reachable: []bool,
infos: std.ArrayList(Info) = .empty,
/// Canonical pair to its `merged` region, so the dataflow lattice is finite.
merged: std.AutoHashMapUnmanaged(u64, Index) = .empty,
/// Collected before any use is judged.
releases: std.ArrayList(Release) = .empty,

/// `static` is every value that cannot dangle, and the root every chain ends at.
pub const Index = enum(u32) { static = 0, _ };

/// An instruction index no body reaches, for a merge's `made_at`.
const no_inst = std.math.maxInt(u32);

const Info = struct {
    parent: Index,
    /// The name that introduced it, which is what a diagnostic calls it.
    token: Token,
    kind: Kind,
    /// The instruction that created it, `no_inst` for a merge.
    made_at: u32 = no_inst,
    /// The two regions a `merged` region stands for.
    members: [2]Index = .{ .static, .static },
};

/// Where a region came from, which is what decides a diagnostic's wording.
const Kind = enum {
    /// The arena parameter. A result belongs here.
    given,
    /// Memory behind a pointer parameter, owned by the caller.
    borrowed,
    /// `Arena.init()` in this function.
    made,
    /// `arena.child()`.
    child,
    /// Different regions on different paths. Outlives only what every member does.
    merged,
};

/// The maker of a value, which a path repasses to remake it.
const Origin = enum(u32) {
    /// No maker seen yet, the identity of `merge`.
    unassigned = std.math.maxInt(u32) - 1,
    /// More than one maker, so no single point remakes the value.
    many = std.math.maxInt(u32),
    _,

    fn at(index: u32) Origin {
        return @enumFromInt(index);
    }

    fn merge(a: Origin, b: Origin) Origin {
        if (a == .unassigned) return b;
        if (b == .unassigned) return a;
        return if (a == b) a else .many;
    }

    /// As an instruction index. The sentinels are indexes no body reaches, so they never block.
    fn barrier(origin: Origin) u32 {
        return @intFromEnum(origin);
    }
};

const Release = struct {
    of: Index,
    at: u32,
    is_destroy: bool,
};

const SlotVal = struct {
    region: Index = .static,
    origin: Origin = .unassigned,
    /// False until a store on some path in, so an untouched slot merges as identity.
    set: bool = false,
};

pub fn run(
    gpa: Allocator,
    types: *const Type,
    tree: *const Ast,
    diagnostics: *Diagnostic.List,
    nir: Nir,
) Allocator.Error!void {
    var region: Region = .{
        .gpa = gpa,
        .types = types,
        .tree = tree,
        .diagnostics = diagnostics,
        .nir = nir,
        .of = try gpa.alloc(Index, nir.insts.len),
        .origin = try gpa.alloc(Origin, nir.insts.len),
        .block_of = try gpa.alloc(u32, nir.insts.len),
        .reachable = try Nir.reachableBlocks(gpa, nir.blocks),
    };
    defer gpa.free(region.of);
    defer gpa.free(region.origin);
    defer gpa.free(region.block_of);
    defer gpa.free(region.reachable);
    defer region.infos.deinit(gpa);
    defer region.merged.deinit(gpa);
    defer region.releases.deinit(gpa);

    @memset(region.of, .static);
    @memset(region.origin, .unassigned);
    for (nir.blocks, 0..) |blk, b| {
        @memset(region.block_of[blk.first..blk.end()], @intCast(b));
    }

    try region.bindParams();
    try region.flow();
    try region.collectReleases();
    try region.checkAll();
}

/// The arena parameter names the region the caller gave. A pointer parameter points
/// into memory it outlives, so it becomes a child of it, and a sibling of any scratch.
fn bindParams(region: *Region) Allocator.Error!void {
    var arena: Index = .static;
    for (region.nir.insts, 0..) |inst, at| {
        if (inst.data != .arg) break;
        if (inst.val.ty != .Arena) continue;
        arena = try region.new(.static, inst.token, .given, @intCast(at));
        region.of[at] = arena;
    }
    for (region.nir.insts, 0..) |inst, at| {
        if (inst.data != .arg) break;
        if (inst.val.ty == .Arena or inst.val.ty == .poisoned) continue;
        if (region.types.isFlat(inst.val.ty)) continue; // a number cannot dangle
        region.of[at] = try region.new(arena, inst.token, .borrowed, @intCast(at));
    }
}

// Dataflow

/// Runs slot state to a fixed point, assigning each instruction its region and origin.
/// Merges only ever deepen, so this terminates.
fn flow(region: *Region) Allocator.Error!void {
    const gpa = region.gpa;
    const blocks = region.nir.blocks;

    // Dense ids for the slots, so a state is a small array.
    const slot_id = try gpa.alloc(u32, region.nir.insts.len);
    defer gpa.free(slot_id);
    @memset(slot_id, no_inst);
    var slot_count: u32 = 0;
    for (region.nir.insts, 0..) |inst, at| {
        if (inst.data != .alloc) continue;
        slot_id[at] = slot_count;
        slot_count += 1;
    }

    const entries = try gpa.alloc(SlotVal, blocks.len * slot_count);
    defer gpa.free(entries);
    @memset(entries, .{});
    const state = try gpa.alloc(SlotVal, slot_count);
    defer gpa.free(state);

    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);
    const queued = try gpa.alloc(bool, blocks.len);
    defer gpa.free(queued);
    @memset(queued, false);

    try work.append(gpa, 0);
    queued[0] = true;

    while (work.pop()) |b| {
        queued[b] = false;
        @memcpy(state, entries[b * slot_count ..][0..slot_count]);

        const blk = blocks[b];
        for (blk.first..blk.end()) |at| {
            try region.visit(@intCast(at), slot_id, state);
        }

        var buf: [2]Nir.Block.Ref = undefined;
        for (Nir.successorsOf(blk.term, &buf)) |next| {
            const succ = @intFromEnum(next);
            const entry = entries[succ * slot_count ..][0..slot_count];
            var changed = false;
            for (entry, state) |*into, val| {
                if (try region.mergeSlot(into, val)) changed = true;
            }
            if (changed and !queued[succ]) {
                queued[succ] = true;
                try work.append(gpa, succ);
            }
        }
    }
}

fn visit(region: *Region, at: u32, slot_id: []const u32, state: []SlotVal) Allocator.Error!void {
    const inst = region.nir.insts[at];
    switch (inst.data) {
        .arg, .alloc => {}, // bound already, and a slot is frame memory
        // A region is minted once per instruction, however often the loop revisits.
        .arena_init => if (region.of[at] == .static) {
            region.of[at] = try region.new(.static, region.nameToken(at, inst), .made, at);
        },
        .arena_child => |parent| if (region.of[at] == .static) {
            region.of[at] = try region.new(
                region.of[parent.i()],
                region.nameToken(at, inst),
                .child,
                at,
            );
        },
        // A value belongs to the arena it came from, and each is its own origin.
        .arena_create => |arena| {
            region.of[at] = region.of[arena.i()];
            region.origin[at] = .at(at);
        },
        .arena_copy => |it| {
            region.of[at] = region.of[it.arena.i()];
            region.origin[at] = .at(at);
        },
        // One arena in, one arena out, so a result lives where the callee allocated.
        .call => |call| {
            region.of[at] = try region.merge(region.of[at], region.callRegion(call.args));
            region.origin[at] = .at(at);
        },
        // The store that put it there is what a path repasses to remake it.
        .load => |slot| {
            const val = state[slot_id[slot.i()]];
            if (!val.set) return;
            region.of[at] = try region.merge(region.of[at], val.region);
            region.origin[at] = region.origin[at].merge(val.origin);
        },
        .store => |it| {
            state[slot_id[it.slot.i()]] = .{
                .region = region.through(it.value),
                .origin = region.origin[it.value.i()],
                .set = true,
            };
        },
        // A tag is a lower bound on everything inside; a number stays a number.
        .field => |it| try region.derive(at, inst, it.base),
        .binary => |it| try region.derive(at, inst, it.lhs),
        .unary, .coerce => |operand| try region.derive(at, inst, operand),
        else => {},
    }
}

fn derive(region: *Region, at: u32, inst: Nir.Inst, base: Ref) Allocator.Error!void {
    if (!region.holdsPointer(inst.val.ty)) return;
    region.of[at] = try region.merge(region.of[at], region.of[base.i()]);
    region.origin[at] = region.origin[at].merge(region.origin[base.i()]);
}

/// A value that cannot reach memory is static however it was derived.
fn through(region: *const Region, ref: Ref) Index {
    const ty = region.nir.get(ref).val.ty;
    return if (region.holdsPointer(ty)) region.of[ref.i()] else .static;
}

fn callRegion(region: *const Region, args: Nir.Range) Index {
    for (region.nir.refs(args)) |arg| {
        if (region.nir.get(arg).val.ty == .Arena) return region.of[arg.i()];
    }
    return .static;
}

fn mergeSlot(region: *Region, into: *SlotVal, val: SlotVal) Allocator.Error!bool {
    if (!val.set) return false;
    if (!into.set) {
        into.* = val;
        return true;
    }
    const grown = try region.merge(into.region, val.region);
    const origin = into.origin.merge(val.origin);
    const changed = grown != into.region or origin != into.origin;
    into.region = grown;
    into.origin = origin;
    return changed;
}

/// The region both possibilities answer for. A merge that already counts the other
/// side absorbs it, which keeps the lattice finite.
fn merge(region: *Region, a: Index, b: Index) Allocator.Error!Index {
    if (a == b or b == .static) return a;
    if (a == .static) return b;
    if (region.covers(a, b)) return a;
    if (region.covers(b, a)) return b;
    if (region.outlives(a, b)) return b;
    if (region.outlives(b, a)) return a;

    const lo = @min(@intFromEnum(a), @intFromEnum(b));
    const hi = @max(@intFromEnum(a), @intFromEnum(b));
    const key = (@as(u64, lo) << 32) | hi;
    const found = try region.merged.getOrPut(region.gpa, key);
    if (found.found_existing) return found.value_ptr.*;

    const minted = try region.new(.static, region.info(a).token, .merged, no_inst);
    region.info(minted).members = .{ @enumFromInt(lo), @enumFromInt(hi) };
    found.value_ptr.* = minted;
    return minted;
}

/// Whether `a` is `b`, or a merge one of whose members already counts `b`.
fn covers(region: *const Region, a: Index, b: Index) bool {
    if (a == b) return true;
    if (a == .static) return false;
    const it = region.info(a);
    if (it.kind != .merged) return false;
    return region.covers(it.members[0], b) or region.covers(it.members[1], b);
}

// Rules

fn collectReleases(region: *Region) Allocator.Error!void {
    for (region.nir.blocks, 0..) |blk, b| {
        if (!region.reachable[b]) continue;
        for (blk.first..blk.end()) |at| {
            const inst = region.nir.insts[at];
            const arena: Ref, const is_destroy = switch (inst.data) {
                .arena_reset => |arena| .{ arena, false },
                .arena_destroy => |arena| .{ arena, true },
                else => continue,
            };
            if (!region.isNamed(arena)) continue; // reported as unnamed instead
            const of = region.of[arena.i()];
            if (of == .static) continue;
            try region.releases.append(region.gpa, .{
                .of = of,
                .at = @intCast(at),
                .is_destroy = is_destroy,
            });
        }
    }
}

fn checkAll(region: *Region) Allocator.Error!void {
    for (region.nir.blocks, 0..) |blk, b| {
        if (!region.reachable[b]) continue;
        for (blk.first..blk.end()) |at| {
            const inst = region.nir.insts[at];
            const pos: Pos = .{ .block = @intCast(b), .order = @intCast(at) };
            try region.checkLive(pos, inst);
            switch (inst.data) {
                .store_field => |it| try region.checkStore(inst, it),
                .arena_reset, .arena_destroy => |arena| {
                    try region.checkNamed(inst, arena);
                    try region.checkArenaAlive(pos, inst, arena);
                },
                .arena_create, .arena_child => |arena| try region.checkArenaAlive(pos, inst, arena),
                .arena_copy => |it| try region.checkArenaAlive(pos, inst, it.arena),
                else => {},
            }
        }
        switch (blk.term) {
            .ret => |r| {
                const value = r.value orelse continue;
                const use: Pos = .{ .block = @intCast(b), .order = term_order };
                try region.checkOperand(use, r.token, r.last, value);
                try region.checkReturn(r, value);
            },
            else => {},
        }
    }
}

/// A value may only be stored into memory it outlives.
fn checkStore(region: *Region, inst: Nir.Inst, store: Nir.Data.StoreField) Allocator.Error!void {
    const src = region.of[store.value.i()];
    const dst = region.of[store.place.i()];
    if (src == .static or dst == .static) return;
    if (region.outlives(src, dst)) return;

    const base = region.fieldBase(store.place);
    const field = region.nir.spanOf(store.place);

    var marks: Marks = .empty;
    defer marks.deinit(region.gpa);
    try region.markOrigin(&marks, src);
    try region.markOrigin(&marks, dst);
    try region.markHome(&marks, base, dst);
    try region.markHome(&marks, store.value, src);
    try marks.append(region.gpa, .{
        .token = field[0],
        .last = field[1],
        .text = try region.print("this {s}", .{try region.livesIn(dst)}),
    });

    try region.diagnostics.add(.{
        .tag = .does_not_live_long_enough,
        .token = inst.token,
        .last = inst.last,
        .message = try region.print("{s} does not live long enough", .{
            try region.label(store.value),
        }),
        .text = try region.print("this {s}", .{try region.livesIn(src)}),
        .marks = try region.diagnostics.marks(marks.items),
        .notes = try region.diagnostics.notes(&.{
            try region.why(src, dst),
            try region.howToStore(inst, store, src, dst),
        }),
    });
}

/// Returning is storing into the caller, so a result may not live in a region this call
/// made. What a parameter gave us is already the caller's.
fn checkReturn(region: *Region, r: Nir.Term.Return, value: Ref) Allocator.Error!void {
    const of = region.of[value.i()];
    if (of == .static or !region.isLocalRegion(of)) return;

    const home = region.regionName(of);

    var marks: Marks = .empty;
    defer marks.deinit(region.gpa);
    try region.markOrigin(&marks, of);
    try region.markHome(&marks, value, of);

    try region.diagnostics.add(.{
        .tag = .does_not_live_long_enough,
        .token = r.token,
        .last = r.last,
        .message = try region.print("{s} does not live long enough to be returned", .{
            try region.label(value),
        }),
        .text = try region.print("returned here, but '{s}' dies first", .{home}),
        .marks = try region.diagnostics.marks(marks.items),
        .notes = try region.diagnostics.notes(&.{
            .{
                .kind = .note,
                .text = try region.print(
                    "a result is stored into the caller, so it has to live in an arena the caller\nalready has. '{s}' is made in this function, and dies with it.",
                    .{home},
                ),
            },
            try region.howToReturn(value),
        }),
    });
}

/// Made inside this call. A merge is local when any member is.
fn isLocalRegion(region: *const Region, index: Index) bool {
    const it = region.info(index);
    return switch (it.kind) {
        .made, .child => true,
        .given, .borrowed => false,
        .merged => region.isLocalRegion(it.members[0]) or region.isLocalRegion(it.members[1]),
    };
}

/// Releasing kills every value in the region, everywhere, so it needs a name: an
/// arena parameter, or a local made with `Arena.init` or `child`.
fn isNamed(region: *const Region, arena: Ref) bool {
    return switch (region.nir.get(arena).data) {
        .arg, .arena_init, .arena_child => true,
        else => false,
    };
}

fn checkNamed(region: *Region, inst: Nir.Inst, arena: Ref) Allocator.Error!void {
    if (region.isNamed(arena)) return;
    const reached = try region.path(arena);
    try region.diagnostics.add(.{
        .tag = .release_needs_a_name,
        .token = inst.token,
        .last = inst.last,
        .message = try region.print(
            "'{s}' is not a name here, so the arena it reaches cannot be released",
            .{reached},
        ),
        .text = try region.print(
            "'{s}' is reached through a pointer, so it has no name here",
            .{reached},
        ),
        .notes = try region.diagnostics.notes(&.{
            .{
                .kind = .note,
                .text = "every value in an arena dies the instant it is released, and this\n" ++
                    "function can see almost none of them. Allocating through a pointer\n" ++
                    "stays safe; releasing does not.",
            },
            .{
                .kind = .help,
                .text = "release it in the function that made it, where it has a name",
            },
        }),
    });
}

// Liveness

/// A position in the graph. `term_order` sits past every instruction in its block.
const Pos = struct { block: u32, order: u32 };
const term_order = std.math.maxInt(u32);

/// A value made before its arena was released and used after is reading freed memory.
fn checkLive(region: *Region, use: Pos, inst: Nir.Inst) Allocator.Error!void {
    var buf: [2]Ref = undefined;
    const span = region.nir.spanOf(@enumFromInt(use.order));
    for (region.nir.operandsOf(inst.data, &buf)) |operand| {
        try region.checkOperand(use, span[0], span[1], operand);
    }
}

fn checkOperand(region: *Region, use: Pos, token: Token, last: Token, operand: Ref) Allocator.Error!void {
    // A handle survives its own reset; `checkArenaAlive` asks if it was destroyed.
    if (region.nir.get(operand).val.ty == .Arena) return;
    if (region.of[operand.i()] == .static) return;

    for (region.releases.items) |release| {
        if (!region.inChain(region.of[operand.i()], release.of)) continue;
        if (try region.releaseSince(release.at, region.origin[operand.i()].barrier(), use)) {
            return region.reportUseAfterRelease(use, token, last, operand, release);
        }
    }
}

/// Whether `of` or an arena it lives inside is `target`, either member counting for a
/// merge, since the release kills that possibility.
fn inChain(region: *const Region, of: Index, target: Index) bool {
    var walk = of;
    while (walk != .static) {
        if (walk == target) return true;
        const it = region.info(walk);
        if (it.kind == .merged) {
            return region.inChain(it.members[0], target) or
                region.inChain(it.members[1], target);
        }
        walk = it.parent;
    }
    return false;
}

/// Whether some path runs `release` then reaches `use` without passing `barrier`.
fn releaseSince(region: *Region, release: u32, barrier: u32, use: Pos) Allocator.Error!bool {
    const rb = region.block_of[release];

    // The straight run from the release to the end of its own block.
    var at = release + 1;
    while (at < region.nir.blocks[rb].end()) : (at += 1) {
        if (at == barrier) return false;
        if (rb == use.block and at == use.order) return true;
    }
    if (rb == use.block and use.order == term_order) return true;
    return region.walkFrom(rb, barrier, use);
}

/// A block containing the barrier ends every path through it.
fn walkFrom(region: *Region, from: u32, barrier: u32, use: Pos) Allocator.Error!bool {
    const gpa = region.gpa;
    const blocks = region.nir.blocks;

    const seen = try gpa.alloc(bool, blocks.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);

    var buf: [2]Nir.Block.Ref = undefined;
    for (Nir.successorsOf(blocks[from].term, &buf)) |next| {
        try work.append(gpa, @intFromEnum(next));
    }

    while (work.pop()) |b| {
        if (seen[b]) continue;
        seen[b] = true;

        const blk = blocks[b];
        var blocked = false;
        var at = blk.first;
        while (at < blk.end()) : (at += 1) {
            if (b == use.block and at == use.order) return true;
            if (at == barrier) {
                blocked = true;
                break;
            }
        }
        if (blocked) continue;
        if (b == use.block and use.order == term_order) return true;

        for (Nir.successorsOf(blk.term, &buf)) |next| {
            try work.append(gpa, @intFromEnum(next));
        }
    }
    return false;
}

fn reportUseAfterRelease(
    region: *Region,
    use: Pos,
    token: Token,
    last: Token,
    operand: Ref,
    release: Release,
) Allocator.Error!void {
    const home = region.regionName(release.of);
    const kill = region.nir.spanOf(@enumFromInt(release.at));
    // Same block and earlier is certain; anything else depends on the path.
    const is_straight = region.block_of[release.at] == use.block and release.at < use.order;

    var marks: Marks = .empty;
    defer marks.deinit(region.gpa);
    try region.markHome(&marks, operand, region.of[operand.i()]);
    try marks.append(region.gpa, .{
        .token = kill[0],
        .last = kill[1],
        .text = if (is_straight)
            try region.print("everything in '{s}' dies here", .{home})
        else
            try region.print("on this path, everything in '{s}' dies here", .{home}),
    });

    try region.diagnostics.add(.{
        .tag = .used_after_release,
        .token = token,
        .last = last,
        .message = if (is_straight)
            try region.print("{s} is used after '{s}' was released", .{
                try region.label(operand), home,
            })
        else
            try region.print("{s} may be used after '{s}' is released", .{
                try region.label(operand), home,
            }),
        .text = if (is_straight)
            "read after its memory was released"
        else
            "read here, on a path that released it",
        .marks = try region.diagnostics.marks(marks.items),
        .notes = try region.diagnostics.notes(&.{.{
            .kind = .help,
            .text = try region.print(
                "read what you need before releasing '{s}', and keep that",
                .{home},
            ),
        }}),
    });
}

/// A destroyed arena cannot hand out memory again. `reset` leaves the handle alive,
/// so only `destroy` ends it.
fn checkArenaAlive(region: *Region, use: Pos, inst: Nir.Inst, arena: Ref) Allocator.Error!void {
    const of = region.of[arena.i()];
    if (of == .static) return;

    for (region.releases.items) |release| {
        if (!release.is_destroy or release.at == use.order) continue;
        if (!region.inChain(of, release.of)) continue;
        const barrier = region.info(release.of).made_at;
        if (!try region.releaseSince(release.at, barrier, use)) continue;

        const home = region.regionName(release.of);
        const kill = region.nir.spanOf(@enumFromInt(release.at));
        const is_straight = region.block_of[release.at] == use.block;

        var marks: Marks = .empty;
        defer marks.deinit(region.gpa);
        try marks.append(region.gpa, .{
            .token = kill[0],
            .last = kill[1],
            .text = if (is_straight)
                try region.print("'{s}' is destroyed here", .{home})
            else
                try region.print("on this path, '{s}' is destroyed here", .{home}),
        });

        try region.diagnostics.add(.{
            .tag = .used_after_release,
            .token = inst.token,
            .last = inst.last,
            .message = if (is_straight)
                try region.print("'{s}' is used after it was destroyed", .{home})
            else
                try region.print("'{s}' may be used after it is destroyed", .{home}),
            .text = "nothing can come from a destroyed arena",
            .marks = try region.diagnostics.marks(marks.items),
            .notes = try region.diagnostics.notes(&.{.{
                .kind = .help,
                .text = "'reset' empties an arena that stays alive; 'destroy' is final",
            }}),
        });
        return;
    }
}

// Regions

fn new(region: *Region, parent: Index, token: Token, kind: Kind, made_at: u32) Allocator.Error!Index {
    try region.infos.append(region.gpa, .{
        .parent = parent,
        .token = token,
        .kind = kind,
        .made_at = made_at,
    });
    return @enumFromInt(region.infos.items.len);
}

fn info(region: *const Region, index: Index) *Info {
    return &region.infos.items[@intFromEnum(index) - 1];
}

/// `static` outlives everything. A merge outlives only what both members do, and is
/// outlived by whatever both are. Otherwise `a` must be an ancestor of `b`.
fn outlives(region: *const Region, a: Index, b: Index) bool {
    if (a == .static) return true;
    if (b == .static) return false;
    const an = region.info(a);
    if (an.kind == .merged) {
        return region.outlives(an.members[0], b) and region.outlives(an.members[1], b);
    }
    const bn = region.info(b);
    if (bn.kind == .merged) {
        return region.outlives(a, bn.members[0]) and region.outlives(a, bn.members[1]);
    }
    var walk = b;
    while (walk != .static) {
        if (walk == a) return true;
        walk = region.info(walk).parent;
    }
    return false;
}

fn holdsPointer(region: *const Region, ty: Type.Index) bool {
    return ty != .poisoned and !region.types.isFlat(ty);
}

// Wording

const Marks = std.ArrayList(Diagnostic.Mark);

fn markOrigin(region: *Region, marks: *Marks, index: Index) Allocator.Error!void {
    if (index == .static) return;
    const it = region.info(index);
    if (it.kind == .merged) {
        try region.markOrigin(marks, it.members[0]);
        try region.markOrigin(marks, it.members[1]);
        return;
    }
    const own = region.tree.tokenSlice(it.token);
    try marks.append(region.gpa, .{
        .token = it.token,
        .text = switch (it.kind) {
            .given => try region.print("'{s}' comes from the caller", .{own}),
            .borrowed => try region.print("the caller owns what '{s}' points at", .{own}),
            .made => try region.print(
                "'{s}' is made here, and dies at the end of this function",
                .{own},
            ),
            .child => try region.print("'{s}' is created here, as a child of '{s}'", .{
                own, region.regionName(it.parent),
            }),
            .merged => unreachable,
        },
    });
}

/// `'box' lives in 'arena'`, on the line that declared it.
fn markHome(region: *Region, marks: *Marks, ref: Ref, index: Index) Allocator.Error!void {
    const token = region.nir.nameOf(ref) orelse return;
    // A region named after this very value would only repeat itself.
    if (index != .static and region.info(index).token == token) return;
    try marks.append(region.gpa, .{
        .token = token,
        .text = try region.print("'{s}' {s}", .{
            region.tree.tokenSlice(token), try region.livesIn(index),
        }),
    });
}

fn livesIn(region: *Region, index: Index) Allocator.Error![]const u8 {
    if (index == .static) return "cannot dangle";
    const it = region.info(index);
    return switch (it.kind) {
        .borrowed => "is borrowed from the caller",
        .merged => try region.print("lives in '{s}' on one path and '{s}' on another", .{
            region.regionName(it.members[0]), region.regionName(it.members[1]),
        }),
        else => try region.print("lives in '{s}'", .{region.tree.tokenSlice(it.token)}),
    };
}

fn why(region: *Region, src: Index, dst: Index) Allocator.Error!Diagnostic.Note {
    const a = region.regionName(src);
    const b = region.regionName(dst);
    const text = if (region.info(src).kind == .merged)
        try region.print(
            "which arena this lives in depends on the path taken, and neither\n'{s}' nor '{s}' outlives '{s}'.",
            .{
                region.regionName(region.info(src).members[0]),
                region.regionName(region.info(src).members[1]),
                b,
            },
        )
    else if (region.info(src).kind == .borrowed)
        try region.print(
            "'{s}' is borrowed. The caller decides how long it lives, so nothing here may\nkeep a pointer to it.",
            .{a},
        )
    else if (region.info(dst).kind == .borrowed)
        try region.print(
            "'{s}' belongs to the caller and outlives this function.\n'{s}' dies at the end of it.",
            .{ b, a },
        )
    else if (region.outlives(dst, src))
        try region.print("'{s}' is a child of '{s}', and a child dies before its parent.", .{ a, b })
    else
        try region.print(
            "'{s}' and '{s}' are siblings.\nNeither outlives the other, so a pointer either way can dangle.",
            .{ a, b },
        );
    return .{ .kind = .note, .text = text };
}

/// The arena a fix names: where the destination lives, or its parent when that is
/// memory the caller lent us.
fn homeArena(region: *const Region, dst: Index) Index {
    if (dst == .static) return dst;
    const it = region.info(dst);
    return switch (it.kind) {
        .borrowed => it.parent,
        .merged => .static, // no single arena to point at
        else => dst,
    };
}

/// States the rule, then shows one way to satisfy it. Which way the author meant is
/// not knowable, so the choice is left open.
fn howToStore(
    region: *Region,
    inst: Nir.Inst,
    store: Nir.Data.StoreField,
    src: Index,
    dst: Index,
) Allocator.Error!Diagnostic.Note {
    const home = region.homeArena(dst);
    if (home == .static) return .{
        .kind = .help,
        .text = "take an arena parameter, and allocate what you store from it",
    };
    const arena = region.regionName(home);
    const value = region.name(store.value) orelse "the value";
    const ty = region.nir.get(store.value).val.ty;

    // An arena is a value, so the same rule applies, but copying one makes no sense.
    if (ty == .Arena) return .{
        .kind = .help,
        .text = try region.print(
            "store '{s}' instead, which outlives this memory, or keep an index rather\nthan the arena itself",
            .{arena},
        ),
    };
    if (region.info(src).kind == .borrowed) return .{
        .kind = .help,
        .text = try region.print(
            "{s} has to own what it keeps. One way, copying into '{s}':",
            .{ try region.label(region.fieldBase(store.place)), arena },
        ),
        .code = try region.print("{s} = {s}.create({s})", .{
            try region.path(store.place),                              arena,
            try region.typeName(region.types.pointeeOf(ty) orelse ty),
        }),
        .at = region.tree.tokenStart(inst.token),
    };
    if (region.types.isCopyable(ty)) return .{
        .kind = .help,
        .text = try region.print("{s}. One way, copying into '{s}':", .{
            try region.rule(store), arena,
        }),
        .code = try region.print("{s} = {s}.copy({s})", .{
            try region.path(store.place), arena, value,
        }),
        .at = region.tree.tokenStart(inst.token),
    };
    // No single instruction made the value, so there is no line to rewrite.
    if (region.origin[store.value.i()] == .many) return .{
        .kind = .help,
        .text = try region.print(
            "{s} on every path. Allocate it from one arena on every branch,\nor copy what it reaches into '{s}' before storing it",
            .{ try region.rule(store), arena },
        ),
    };
    // A pointer cannot be copied, so the allocation itself has to move.
    return .{
        .kind = .help,
        .text = try region.print("{s}. One way, allocating it from '{s}':", .{
            try region.rule(store), arena,
        }),
        .code = try region.print("var {s} = {s}", .{
            value, try region.allocatedFrom(region.originOf(store.value), arena),
        }),
        .at = region.anchor(store.value),
    };
}

fn howToReturn(region: *Region, value: Ref) Allocator.Error!Diagnostic.Note {
    for (region.infos.items) |it| {
        if (it.kind != .given) continue;
        const arena = region.tree.tokenSlice(it.token);
        // No single instruction made the value, so there is no line to rewrite.
        if (region.origin[value.i()] == .many) return .{
            .kind = .help,
            .text = try region.print(
                "{s} has to outlive this function on every path, so allocate it\nfrom '{s}' on every branch",
                .{ try region.label(value), arena },
            ),
        };
        return .{
            .kind = .help,
            .text = try region.print(
                "{s} has to outlive this function. One way, allocating it from '{s}':",
                .{ try region.label(value), arena },
            ),
            .code = try region.print("var {s} = {s}", .{
                region.name(value) orelse "result",
                try region.allocatedFrom(region.originOf(value), arena),
            }),
            .at = region.anchor(value),
        };
    }
    return .{
        .kind = .help,
        .text = "take an arena parameter, and allocate the result from it",
        .code = "fn f(arena: Arena) ...",
    };
}

/// What actually made a value, chasing a load back to its slot, so a fix rewrites the
/// maker rather than the mention.
fn originOf(region: *const Region, ref: Ref) Ref {
    const origin = region.origin[ref.i()];
    if (origin == .unassigned or origin == .many) return ref;
    return @enumFromInt(@intFromEnum(origin));
}

/// How to make the value in `arena` instead: the call that made it with its arena
/// swapped, or a plain `create` when nothing else made it.
fn allocatedFrom(region: *Region, ref: Ref, arena: []const u8) Allocator.Error![]const u8 {
    const inst = region.nir.get(ref);
    const called = switch (inst.data) {
        .call => |call| call,
        else => {
            const ty = inst.val.ty;
            return region.print("{s}.create({s})", .{
                arena, try region.typeName(region.types.pointeeOf(ty) orelse ty),
            });
        },
    };

    const gpa = region.diagnostics.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, region.tree.tokenSlice(region.nir.get(called.callee).token));
    try out.append(gpa, '(');
    for (region.nir.refs(called.args), 0..) |arg, at| {
        if (at > 0) try out.appendSlice(gpa, ", ");
        if (region.nir.get(arg).val.ty == .Arena) {
            try out.appendSlice(gpa, arena);
        } else {
            try out.appendSlice(gpa, region.argText(arg));
        }
    }
    try out.append(gpa, ')');
    return out.items;
}

fn anchor(region: *const Region, ref: Ref) ?u32 {
    return region.tree.tokenStart(region.nir.nameOf(ref) orelse return null);
}

fn argText(region: *const Region, ref: Ref) []const u8 {
    return region.name(ref) orelse region.tree.tokenSlice(region.nir.get(ref).token);
}

/// The thing the code has to satisfy, as in `'probe' has to outlive 'second'`.
fn rule(region: *Region, store: Nir.Data.StoreField) Allocator.Error![]const u8 {
    const held = region.label(region.fieldBase(store.place)) catch "this memory";
    return region.print("{s} has to outlive {s}", .{ try region.label(store.value), held });
}

fn fieldBase(region: *const Region, place: Ref) Ref {
    return switch (region.nir.get(place).data) {
        .field => |it| it.base,
        else => place,
    };
}

fn regionName(region: *const Region, index: Index) []const u8 {
    if (index == .static) return "static";
    return region.tree.tokenSlice(region.info(index).token);
}

/// Quoted when the value has a name, and plain prose when it does not.
fn label(region: *Region, ref: Ref) Allocator.Error![]const u8 {
    const named = region.name(ref) orelse return "this value";
    return region.print("'{s}'", .{named});
}

fn name(region: *const Region, ref: Ref) ?[]const u8 {
    const token = region.nir.nameOf(ref) orelse return null;
    return region.tree.tokenSlice(token);
}

fn nameToken(region: *const Region, at: u32, inst: Nir.Inst) Token {
    return region.nir.nameOf(@enumFromInt(at)) orelse inst.token;
}

/// `b.arena`, for an expression a name cannot stand in for.
fn path(region: *Region, ref: Ref) Allocator.Error![]const u8 {
    const inst = region.nir.get(ref);
    const field = switch (inst.data) {
        .field => |f| f,
        else => return region.name(ref) orelse region.tree.tokenSlice(inst.token),
    };
    const owner = region.nir.get(field.base);
    const base = region.name(field.base) orelse region.tree.tokenSlice(owner.token);
    return region.print("{s}.{s}", .{ base, region.tree.tokenSlice(inst.last) });
}

fn typeName(region: *Region, ty: Type.Index) Allocator.Error![]const u8 {
    return Type.spell(region.types, ty, region.diagnostics.allocator());
}

fn print(region: *Region, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
    return region.diagnostics.print(fmt, args);
}
