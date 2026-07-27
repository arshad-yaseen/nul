//! Proves the memory model over one function body.
//!
//! > Every pointer reachable from a value in some arena points into an arena that
//! > outlives it.
//!
//! Storing preserves that, so the whole check is: a value may only be stored into memory
//! it outlives. Regions form a tree, since `child` is the only way to make one, and
//! "outlives" is an ancestor walk. Nothing here crosses a function boundary.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Nir = @import("Nir.zig");
const Type = @import("Type.zig");

const Region = @This();
const Token = Ast.TokenIndex;

gpa: Allocator,
pool: *const InternPool,
tree: *const Ast,
diagnostics: *Diagnostic.List,
nir: Nir,
/// The region each instruction's value lives in.
of: []Index,
infos: std.ArrayList(Info) = .empty,

/// `static` is every value that cannot dangle, and the root every chain ends at.
pub const Index = enum(u32) { static = 0, _ };

const Info = struct {
    parent: Index,
    /// The name that introduced it, which is what a diagnostic calls it.
    token: Token,
    kind: Kind,
    /// The instruction that last released it, or `never`.
    released: u32 = never,

    /// Made inside this call, so it dies when the frame does.
    fn isLocal(it: Info) bool {
        return it.kind == .made or it.kind == .child;
    }
};

/// Where a region came from. Every diagnostic reads this to decide its wording, since
/// what a reader needs told about a borrowed pointer is not what they need told about a
/// scratch arena.
const Kind = enum {
    /// The arena parameter. A result belongs here.
    given,
    /// Memory behind a pointer parameter, owned by the caller.
    borrowed,
    /// `Arena.init()` in this function.
    made,
    /// `arena.child()`.
    child,
};

const never = std.math.maxInt(u32);

pub fn run(
    gpa: Allocator,
    pool: *const InternPool,
    tree: *const Ast,
    diagnostics: *Diagnostic.List,
    nir: Nir,
) Allocator.Error!void {
    var region: Region = .{
        .gpa = gpa,
        .pool = pool,
        .tree = tree,
        .diagnostics = diagnostics,
        .nir = nir,
        .of = try gpa.alloc(Index, nir.insts.len),
    };
    defer gpa.free(region.of);
    defer region.infos.deinit(gpa);
    @memset(region.of, .static);

    try region.bindParams();
    for (nir.insts, 0..) |inst, at| try region.visit(@intCast(at), inst);
}

/// The arena parameter names the region the caller gave. Every pointer parameter points
/// into memory that arena outlives, so each becomes a child of it: a sibling of any
/// scratch this function makes, and therefore not something scratch may be stored into.
fn bindParams(region: *Region) Allocator.Error!void {
    var arena: Index = .static;
    for (region.nir.insts, 0..) |inst, at| {
        if (inst.tag != .arg) break;
        if (inst.ty != .Arena) continue;
        arena = try region.new(.static, inst.token, .given);
        region.of[at] = arena;
    }
    for (region.nir.insts, 0..) |inst, at| {
        if (inst.tag != .arg) break;
        if (inst.ty == .Arena or inst.ty == .poisoned) continue;
        if (region.pool.isFlat(inst.ty)) continue; // a number cannot dangle
        region.of[at] = try region.new(arena, inst.token, .borrowed);
    }
}

fn visit(region: *Region, at: u32, inst: Nir.Inst) Allocator.Error!void {
    try region.checkLive(at, inst);

    region.of[at] = switch (inst.tag) {
        .arg => region.of[at], // bound already
        .arena_init => try region.new(.static, region.nameToken(at, inst), .made),
        .arena_child => try region.new(region.of[inst.lhs], region.nameToken(at, inst), .child),
        // A value belongs to the arena it was allocated from, and `copy` relabels into
        // the arena it was copied by.
        .arena_create, .arena_copy => region.of[inst.lhs],
        // One arena in, one arena out: a result lives where the callee allocated.
        .call => region.callRegion(inst),
        // A tag is a lower bound on everything inside, so a field is at least its base
        // when it can reach memory at all. A number read out of an arena is a number.
        .field, .binary, .unary => if (region.holdsPointer(inst.ty))
            region.of[inst.lhs]
        else
            .static,
        else => .static,
    };

    switch (inst.tag) {
        .store_field => try region.checkStore(inst),
        .ret => try region.checkReturn(inst),
        .arena_reset, .arena_destroy => try region.release(at, inst),
        // Scope end is not a release, nothing can name the arena past here.
        .arena_end => {},
        else => {},
    }
}

fn callRegion(region: *const Region, inst: Nir.Inst) Index {
    for (region.nir.callArgs(inst)) |arg| {
        if (region.nir.insts[arg].ty == .Arena) return region.of[arg];
    }
    return .static;
}

// Rules

/// A value may only be stored into memory it outlives.
fn checkStore(region: *Region, inst: Nir.Inst) Allocator.Error!void {
    const src = region.of[inst.rhs];
    const dst = region.of[inst.lhs];
    if (src == .static or dst == .static) return;
    if (region.outlives(src, dst)) return;

    const base = region.nir.insts[inst.lhs].lhs;
    const field = region.nir.spanOf(inst.lhs);

    var marks: Marks = .empty;
    defer marks.deinit(region.gpa);
    try region.markOrigin(&marks, src);
    try region.markOrigin(&marks, dst);
    try region.markHome(&marks, base, dst);
    try region.markHome(&marks, inst.rhs, src);
    try marks.append(region.gpa, .{
        .token = field[0],
        .last = field[1],
        .text = try region.print("this {s}", .{try region.livesIn(dst)}),
    });

    try region.diagnostics.add(.{
        .tag = .does_not_live_long_enough,
        .token = inst.token,
        .last = inst.last,
        .message = try region.print("{s} does not live long enough", .{try region.label(inst.rhs)}),
        .text = try region.print("this {s}", .{try region.livesIn(src)}),
        .marks = try region.diagnostics.marks(marks.items),
        .notes = try region.diagnostics.notes(&.{
            try region.why(src, dst),
            try region.howToStore(inst, src, dst),
        }),
    });
}

/// Returning is storing into the caller, so a result may not live in a region this call
/// made. What a parameter gave us is already the caller's.
fn checkReturn(region: *Region, inst: Nir.Inst) Allocator.Error!void {
    const returned = (@as(Nir.OptionalIndex, @enumFromInt(inst.lhs))).unwrap() orelse return;
    const value: u32 = @intFromEnum(returned);
    const of = region.of[value];
    if (of == .static or !region.info(of).isLocal()) return;

    const home = region.regionName(of);

    var marks: Marks = .empty;
    defer marks.deinit(region.gpa);
    try region.markOrigin(&marks, of);
    try region.markHome(&marks, value, of);

    try region.diagnostics.add(.{
        .tag = .does_not_live_long_enough,
        .token = inst.token,
        .last = inst.last,
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

/// Releasing kills every value in the region, everywhere in the program, so it needs a
/// name: an arena parameter, or a local made with `Arena.init` or `child`.
fn release(region: *Region, at: u32, inst: Nir.Inst) Allocator.Error!void {
    const receiver = region.nir.insts[inst.lhs];
    switch (receiver.tag) {
        .arg, .arena_init, .arena_child => {},
        else => {
            const reached = try region.path(inst.lhs);
            return region.diagnostics.add(.{
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
        },
    }
    const of = region.of[inst.lhs];
    if (of != .static) region.info(of).released = at;
}

/// A value made before its arena was released, and used after, is reading freed memory.
fn checkLive(region: *Region, at: u32, inst: Nir.Inst) Allocator.Error!void {
    var buf: [2]u32 = undefined;
    for (region.operands(inst, &buf)) |operand| {
        // An arena handle survives its own reset; only what it held is gone.
        if (region.nir.insts[operand].ty == .Arena) continue;

        var walk = region.of[operand];
        while (walk != .static) {
            const it = region.info(walk);
            if (it.released != never and operand < it.released) {
                return region.reportUseAfterRelease(at, operand, walk);
            }
            walk = it.parent;
        }
    }
}

fn reportUseAfterRelease(region: *Region, at: u32, operand: u32, of: Index) Allocator.Error!void {
    const home = region.regionName(of);
    const released = region.info(of).released;
    const kill = region.nir.spanOf(released);
    const use = region.nir.spanOf(at);

    var marks: Marks = .empty;
    defer marks.deinit(region.gpa);
    try region.markHome(&marks, operand, of);
    try marks.append(region.gpa, .{
        .token = kill[0],
        .last = kill[1],
        .text = try region.print("everything in '{s}' dies here", .{home}),
    });

    try region.diagnostics.add(.{
        .tag = .used_after_release,
        .token = use[0],
        .last = use[1],
        .message = try region.print("{s} is used after '{s}' was released", .{
            try region.label(operand), home,
        }),
        .text = "read after its memory was released",
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

// Regions

fn new(region: *Region, parent: Index, token: Token, kind: Kind) Allocator.Error!Index {
    try region.infos.append(region.gpa, .{ .parent = parent, .token = token, .kind = kind });
    return @enumFromInt(region.infos.items.len);
}

fn info(region: *const Region, index: Index) *Info {
    return &region.infos.items[@intFromEnum(index) - 1];
}

/// `static` outlives everything; otherwise `a` must be `b` or an ancestor of it.
fn outlives(region: *const Region, a: Index, b: Index) bool {
    if (a == .static) return true;
    var walk = b;
    while (walk != .static) {
        if (walk == a) return true;
        walk = region.info(walk).parent;
    }
    return false;
}

fn holdsPointer(region: *const Region, ty: Type.Index) bool {
    return ty != .poisoned and !region.pool.isFlat(ty);
}

// Wording

const Marks = std.ArrayList(Diagnostic.Mark);

/// Where the region came from, said the way that region deserves.
fn markOrigin(region: *Region, marks: *Marks, index: Index) Allocator.Error!void {
    if (index == .static) return;
    const it = region.info(index);
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
        },
    });
}

/// `'box' lives in 'arena'`, on the line that declared it.
fn markHome(region: *Region, marks: *Marks, inst: u32, index: Index) Allocator.Error!void {
    const token = region.nir.nameOf(inst) orelse return;
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
    const own = region.tree.tokenSlice(it.token);
    return switch (it.kind) {
        .borrowed => "is borrowed from the caller",
        else => try region.print("lives in '{s}'", .{own}),
    };
}

/// Why the two regions cannot be ordered, which is the whole explanation.
fn why(region: *Region, src: Index, dst: Index) Allocator.Error!Diagnostic.Note {
    const a = region.regionName(src);
    const b = region.regionName(dst);
    const text = if (region.info(src).kind == .borrowed)
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

/// The fix names a real arena: the one the destination lives in, or its parent when the
/// destination is memory the caller lent us.
fn homeArena(region: *const Region, dst: Index) Index {
    if (dst == .static) return dst;
    return if (region.info(dst).kind == .borrowed) region.info(dst).parent else dst;
}

/// Names what has to become true, then shows one way to get there. The compiler cannot
/// know which way the author meant, so it states the rule and leaves the choice.
fn howToStore(region: *Region, inst: Nir.Inst, src: Index, dst: Index) Allocator.Error!Diagnostic.Note {
    const home = region.homeArena(dst);
    if (home == .static) return .{
        .kind = .help,
        .text = "take an arena parameter, and allocate what you store from it",
    };
    const arena = region.regionName(home);
    const value = region.name(inst.rhs) orelse "the value";
    const ty = region.nir.insts[inst.rhs].ty;

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
            .{ try region.label(region.nir.insts[inst.lhs].lhs), arena },
        ),
        .code = try region.print("{s} = {s}.create({s})", .{
            try region.destination(inst),                                   arena,
            try region.typeName(Type.pointeeOf(region.pool, ty) orelse ty),
        }),
        .at = region.tree.tokenStart(inst.token),
    };
    if (Type.isCopyable(region.pool, ty)) return .{
        .kind = .help,
        .text = try region.print("{s}. One way, copying into '{s}':", .{
            try region.rule(inst), arena,
        }),
        .code = try region.print("{s} = {s}.copy({s})", .{
            try region.destination(inst), arena, value,
        }),
        .at = region.tree.tokenStart(inst.token),
    };
    // A pointer cannot be copied, so the allocation itself has to move.
    return .{
        .kind = .help,
        .text = try region.print("{s}. One way, allocating it from '{s}':", .{
            try region.rule(inst), arena,
        }),
        .code = try region.print("var {s} = {s}", .{ value, try region.allocatedFrom(inst.rhs, arena) }),
        .at = region.anchor(inst.rhs),
    };
}

fn howToReturn(region: *Region, value: u32) Allocator.Error!Diagnostic.Note {
    for (region.infos.items) |it| {
        if (it.kind != .given) continue;
        return .{
            .kind = .help,
            .text = try region.print(
                "{s} has to outlive this function. One way, allocating it from '{s}':",
                .{ try region.label(value), region.tree.tokenSlice(it.token) },
            ),
            .code = try region.print("var {s} = {s}", .{
                region.name(value) orelse "result",
                try region.allocatedFrom(value, region.tree.tokenSlice(it.token)),
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

/// How to make the value in `arena` instead: the call that produced it with its arena
/// swapped, or a plain `create` when nothing else made it.
fn allocatedFrom(region: *Region, inst: u32, arena: []const u8) Allocator.Error![]const u8 {
    const it = region.nir.insts[inst];
    if (it.tag != .call) {
        const ty = it.ty;
        return region.print("{s}.create({s})", .{
            arena, try region.typeName(Type.pointeeOf(region.pool, ty) orelse ty),
        });
    }

    const gpa = region.diagnostics.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, region.tree.tokenSlice(region.nir.insts[it.lhs].token));
    try out.append(gpa, '(');
    for (region.nir.callArgs(it), 0..) |arg, at| {
        if (at > 0) try out.appendSlice(gpa, ", ");
        if (region.nir.insts[arg].ty == .Arena) {
            try out.appendSlice(gpa, arena);
        } else {
            try out.appendSlice(gpa, region.argText(arg));
        }
    }
    try out.append(gpa, ')');
    return out.items;
}

/// The line a fix replaces: the one that declared the value.
fn anchor(region: *const Region, inst: u32) ?u32 {
    return region.tree.tokenStart(region.nir.nameOf(inst) orelse return null);
}

/// What an argument was written as: its name, or the token it came from.
fn argText(region: *const Region, inst: u32) []const u8 {
    return region.name(inst) orelse region.tree.tokenSlice(region.nir.insts[inst].token);
}

/// `'probe' has to outlive 'second'`: the thing the code has to satisfy.
fn rule(region: *Region, inst: Nir.Inst) Allocator.Error![]const u8 {
    const held = region.label(region.nir.insts[inst.lhs].lhs) catch "this memory";
    return region.print("{s} has to outlive {s}", .{ try region.label(inst.rhs), held });
}

fn regionName(region: *const Region, index: Index) []const u8 {
    if (index == .static) return "static";
    return region.tree.tokenSlice(region.info(index).token);
}

/// Quoted when the value has a name, and plain prose when it does not.
fn label(region: *Region, inst: u32) Allocator.Error![]const u8 {
    const named = region.name(inst) orelse return "this value";
    return region.print("'{s}'", .{named});
}

fn name(region: *const Region, inst: u32) ?[]const u8 {
    const token = region.nir.nameOf(inst) orelse return null;
    return region.tree.tokenSlice(token);
}

/// The name a region takes when the instruction is bound to a local.
fn nameToken(region: *const Region, at: u32, inst: Nir.Inst) Token {
    return region.nir.nameOf(at) orelse inst.token;
}

/// `b.arena`, for an expression a name cannot stand in for.
fn path(region: *Region, inst: u32) Allocator.Error![]const u8 {
    const it = region.nir.insts[inst];
    if (it.tag != .field) return region.name(inst) orelse region.tree.tokenSlice(it.token);
    const base = region.name(it.lhs) orelse region.tree.tokenSlice(region.nir.insts[it.lhs].token);
    return region.print("{s}.{s}", .{ base, region.tree.tokenSlice(it.last) });
}

/// `box.item`, the destination a fix has to name.
fn destination(region: *Region, inst: Nir.Inst) Allocator.Error![]const u8 {
    return region.path(inst.lhs);
}

fn typeName(region: *Region, ty: Type.Index) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(region.diagnostics.allocator());
    Type.write(region.pool, ty, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn print(region: *Region, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
    return region.diagnostics.print(fmt, args);
}

fn operands(region: *const Region, inst: Nir.Inst, buf: *[2]u32) []const u32 {
    return switch (inst.tag) {
        .store_field, .binary => blk: {
            buf[0] = inst.lhs;
            buf[1] = inst.rhs;
            break :blk buf[0..2];
        },
        .field, .unary, .arena_copy => blk: {
            buf[0] = if (inst.tag == .arena_copy) inst.rhs else inst.lhs;
            break :blk buf[0..1];
        },
        .ret => blk: {
            const value = (@as(Nir.OptionalIndex, @enumFromInt(inst.lhs))).unwrap() orelse
                break :blk buf[0..0];
            buf[0] = @intFromEnum(value);
            break :blk buf[0..1];
        },
        // Already contiguous in `extra`, so no buffer is needed.
        .call => region.nir.callArgs(inst),
        else => buf[0..0],
    };
}
