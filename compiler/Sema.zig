//! Names, types, and signatures.
//!
//! Runs on a tree that parsed cleanly. Resolves every top level name, gives every
//! declaration a type, and checks the part of the memory model a signature settles on
//! its own. Bodies are lowered to `Ir` by a later pass, and nothing here looks inside
//! one, which is what `spec.md` means by signature sufficiency.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Ir = @import("Ir.zig");

const Sema = @This();

gpa: Allocator,
/// Diagnostic strings are built here and freed in one go by the caller, so nothing
/// in a `Diagnostic` has to be owned individually.
arena: Allocator,
tree: Ast,
ip: *InternPool,

decls: std.MultiArrayList(Decl),
/// Name to declaration. One namespace per file, and for now there is one file.
decl_map: std.AutoArrayHashMapUnmanaged(InternPool.String, Decl.Index),
fns: std.MultiArrayList(Fn),
/// Every function's parameters, back to back. `Fn` holds the range.
params: std.MultiArrayList(Param),

/// Named struct types whose fields are not resolved yet. Deferring them is what
/// separates an ordering from a cycle: `let P = *Node` above `let Node = struct
/// { next: P }` needs only Node's identity, which exists the moment it is interned.
pending_fields: std.ArrayList(PendingFields),

/// One lowered body per entry in `fns`, in the same order.
bodies: std.ArrayList(Ir),

// Lowering state, reused across functions rather than reallocated per function.
insts: std.MultiArrayList(Ir.Inst),
ir_extra: std.ArrayList(u32),
ir_slots: std.MultiArrayList(Ir.Slot),
/// Names visible in the function being lowered, innermost last. A function has few,
/// so a reverse scan beats a hash map and keeps shadowing free.
locals: std.MultiArrayList(Local),
/// Where the innermost block's names begin, so it can truncate on the way out and
/// so a redeclaration in the same block can be told from shadowing an outer one.
block_top: u32,
/// Which function is being lowered, for the return type check.
current_fn: u32,

diagnostics: std.ArrayList(Diagnostic),

const PendingFields = struct { type: InternPool.Index, node: Ast.Node.Index };

/// A name bound inside a function body.
const Local = struct {
    name: InternPool.String,
    /// For a `let`, the value itself. For a `var`, the pointer to its slot.
    ref: Ir.Inst.Index,
    is_slot: bool,
    node: Ast.Node.Index,
};

/// What a name turned out to mean. The same answer serves type resolution and body
/// lowering; only the scope chain differs, and at signature time it is just the file.
const Resolved = union(enum) {
    local: u32,
    decl: Decl.Index,
    builtin_type: InternPool.Index,
    not_found,
};

pub const Decl = struct {
    name: InternPool.String,
    /// The `fn_decl`, `let_decl`, or `var_decl` node.
    node: Ast.Node.Index,
    kind: Kind,
    /// The comptime value the name stands for, once resolved.
    value: InternPool.OptionalIndex,
    state: State,

    pub const Kind = enum { function, binding };
    /// `resolving` is both the cycle guard and the reason a struct can name itself:
    /// its type is recorded before its fields are looked at.
    pub const State = enum { unresolved, resolving, resolved };
    pub const Index = enum(u32) { _ };
};

pub const Param = struct {
    name: InternPool.String,
    type: InternPool.Index,
    node: Ast.Node.Index,
};

pub const Fn = struct {
    decl: Decl.Index,
    node: Ast.Node.Index,
    params_start: u32,
    params_len: u32,
    return_type: InternPool.Index,
    /// Which parameter results are allocated into. The model allows exactly one, so
    /// this is the whole region story a caller needs from a signature.
    arena_param: u32,

    pub const no_arena = std.math.maxInt(u32);
};

/// The primitives, plus one placeholder.
///
/// `Arena` does not belong here. It is a library type, not a language primitive, and
/// binding it by name means `use std.mem` followed by `mem.Arena` cannot work. What
/// the region pass actually needs is the interned identity, not the spelling, so once
/// modules resolve, `std.mem.Arena` is looked up once and compared by index, and this
/// entry goes away. Until then a declaration of the same name is rejected rather than
/// silently ignored.
const builtin_types = [_]struct { []const u8, InternPool.Index }{
    .{ "i64", .type_i64 },
    .{ "str", .type_str },
    .{ "bool", .type_bool },
    .{ "void", .type_void },
    .{ "type", .type_type },
    .{ "Arena", .type_arena },
};

fn builtinType(text: []const u8) ?InternPool.Index {
    inline for (builtin_types) |b| {
        if (std.mem.eql(u8, b[0], text)) return b[1];
    }
    return null;
}

pub fn init(gpa: Allocator, arena: Allocator, tree: Ast, ip: *InternPool) Sema {
    return .{
        .gpa = gpa,
        .arena = arena,
        .tree = tree,
        .ip = ip,
        .decls = .empty,
        .decl_map = .empty,
        .fns = .empty,
        .params = .empty,
        .pending_fields = .empty,
        .bodies = .empty,
        .insts = .empty,
        .ir_extra = .empty,
        .ir_slots = .empty,
        .locals = .empty,
        .block_top = 0,
        .current_fn = 0,
        .diagnostics = .empty,
    };
}

pub fn deinit(sema: *Sema) void {
    sema.decls.deinit(sema.gpa);
    sema.decl_map.deinit(sema.gpa);
    sema.fns.deinit(sema.gpa);
    sema.params.deinit(sema.gpa);
    sema.pending_fields.deinit(sema.gpa);
    for (sema.bodies.items) |*ir| ir.deinit(sema.gpa);
    sema.bodies.deinit(sema.gpa);
    sema.insts.deinit(sema.gpa);
    sema.ir_extra.deinit(sema.gpa);
    sema.ir_slots.deinit(sema.gpa);
    sema.locals.deinit(sema.gpa);
    sema.diagnostics.deinit(sema.gpa);
    sema.* = undefined;
}

/// Names, then values, then signatures, then bodies. Only the last two orderings
/// matter: a call is checked against a signature, so every signature exists before
/// any body. Values resolve themselves on demand, so declaration order is irrelevant.
pub fn analyze(sema: *Sema) Allocator.Error!void {
    try sema.collectDecls();
    try sema.resolveDecls();
    try sema.resolveSignatures();
    try sema.lowerBodies();
}

// Names
//
// One lookup, one chain. During signature resolution `locals` is empty, so the same
// walk that finds a parameter inside a body falls straight through to the file.

fn lookup(sema: *Sema, text: []const u8) Allocator.Error!Resolved {
    const name = try sema.ip.getString(sema.gpa, text);

    const names = sema.locals.items(.name);
    var i = sema.locals.len;
    while (i > 0) {
        i -= 1;
        if (names[i] == name) return .{ .local = @intCast(i) };
    }

    if (sema.decl_map.get(name)) |decl| return .{ .decl = decl };
    if (builtinType(text)) |ty| return .{ .builtin_type = ty };
    return .not_found;
}

// Declarations

fn collectDecls(sema: *Sema) Allocator.Error!void {
    const tree = sema.tree;
    const roots = tree.full(.root).root;

    // An upper bound, since `use` declarations do not become names. Reserving it
    // means the whole scan runs without another allocation.
    try sema.decls.ensureTotalCapacity(sema.gpa, roots.len);
    try sema.decl_map.ensureTotalCapacity(sema.gpa, roots.len);

    for (roots) |node| {
        var kind: Decl.Kind = undefined;
        var name_token: Ast.TokenIndex = undefined;
        switch (tree.full(node)) {
            .fn_decl => |f| {
                kind = .function;
                name_token = f.name_token;
            },
            .var_decl => |v| {
                kind = .binding;
                name_token = v.name_token;
            },
            // `use` waits for modules, and anything else was already reported.
            else => continue,
        }

        const text = tree.tokenSlice(name_token);
        if (builtinType(text) != null) {
            // Resolution checks builtins first, so letting this through would mean
            // silently using the language's type wherever the programmer meant theirs.
            try sema.errShadowsBuiltin(name_token, text);
            continue;
        }

        const name = try sema.ip.getString(sema.gpa, text);
        const gop = try sema.decl_map.getOrPut(sema.gpa, name);
        if (gop.found_existing) {
            try sema.errDuplicate(name_token, sema.decls.items(.node)[@intFromEnum(gop.value_ptr.*)], "declared again in this file");
            continue;
        }

        gop.value_ptr.* = @enumFromInt(sema.decls.len);
        sema.decls.appendAssumeCapacity(.{
            .name = name,
            .node = node,
            .kind = kind,
            .value = .none,
            .state = .unresolved,
        });
    }
}

/// Forces every declaration, so one nothing refers to is still checked, then fills
/// in the struct fields that were held back.
fn resolveDecls(sema: *Sema) Allocator.Error!void {
    for (0..sema.decls.len) |i| _ = try sema.declValue(@enumFromInt(i));

    // Resolving a field can name a struct that has not been reached yet, which
    // appends here, so this walks forward rather than iterating a fixed slice.
    var i: usize = 0;
    while (i < sema.pending_fields.items.len) : (i += 1) {
        const pending = sema.pending_fields.items[i];
        try sema.resolveFields(pending.type, sema.tree.full(pending.node).struct_type);
    }
    sema.pending_fields.clearRetainingCapacity();
}

/// What a name stands for, resolved the first time it is asked for. Laziness is what
/// makes declaration order irrelevant, and the `resolving` state is what lets a
/// struct name itself: the type is interned and recorded before any field is read.
fn declValue(sema: *Sema, decl: Decl.Index) Allocator.Error!?InternPool.Index {
    const i = @intFromEnum(decl);
    const decls = sema.decls.slice();

    switch (decls.items(.state)[i]) {
        .resolved => return decls.items(.value)[i].unwrap(),
        .resolving => {
            try sema.errCycle(decls.items(.node)[i]);
            decls.items(.state)[i] = .resolved; // said once is enough
            return null;
        },
        .unresolved => {},
    }

    // A function is not a value. It is reached through the signature table instead.
    if (decls.items(.kind)[i] == .function) {
        decls.items(.state)[i] = .resolved;
        return null;
    }

    decls.items(.state)[i] = .resolving;
    const init_expr = sema.tree.full(decls.items(.node)[i]).var_decl.init_expr;

    if (sema.tree.nodeTag(init_expr) == .struct_type) {
        const fields = sema.tree.full(init_expr).struct_type;
        const ty = try sema.ip.getStructType(
            sema.gpa,
            init_expr,
            decls.items(.name)[i].toOptional(),
            @intCast(fields.len),
        );
        decls.items(.value)[i] = ty.toOptional();
        decls.items(.state)[i] = .resolved;
        try sema.pending_fields.append(sema.gpa, .{ .type = ty, .node = init_expr });
        return ty;
    }

    const value = try sema.evalComptime(init_expr);
    decls.items(.value)[i] = if (value) |v| v.toOptional() else .none;
    decls.items(.state)[i] = .resolved;
    return value;
}

fn resolveFields(sema: *Sema, ty: InternPool.Index, fields: []const Ast.Node.Index) Allocator.Error!void {
    for (fields, 0..) |node, i| {
        const f = sema.tree.full(node).field;
        sema.ip.setStructField(ty, @intCast(i), .{
            .name = try sema.ip.getString(sema.gpa, sema.tree.tokenSlice(f.name_token)),
            // A field whose type failed stays `void`, so later passes stay total.
            .type = (try sema.resolveType(f.type_expr)) orelse .type_void,
        });
    }
}

// Values
//
// One evaluator. A type is a comptime value whose type is `type`, so a type
// expression is not a separate grammar and does not get a separate walk.

/// `null` means the error was reported and the caller should carry on.
fn evalComptime(sema: *Sema, node: Ast.Node.Index) Allocator.Error!?InternPool.Index {
    const tree = sema.tree;
    switch (tree.full(node)) {
        .grouped => |child| return sema.evalComptime(child),

        .int_literal => |token| {
            const text = tree.tokenSlice(token);
            const value = std.fmt.parseInt(i64, text, 0) catch {
                try sema.errBadInt(node, text);
                return null;
            };
            return try sema.ip.get(sema.gpa, .{ .int = value });
        },
        .str_literal => |token| {
            // Escapes are not decoded yet, so this is the literal as written.
            const raw = tree.tokenSlice(token);
            const body = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            return try sema.ip.get(sema.gpa, .{ .str = try sema.ip.getString(sema.gpa, body) });
        },
        .bool_literal => |b| return if (b.value) .value_true else .value_false,

        .ident => |token| {
            const text = tree.tokenSlice(token);
            switch (try sema.lookup(text)) {
                .builtin_type => |ty| return ty,
                .decl => |decl| {
                    if (try sema.declValue(decl)) |value| return value;
                    try sema.errNotComptime(node, text);
                    return null;
                },
                .local => {
                    try sema.errNotComptime(node, text);
                    return null;
                },
                .not_found => {
                    try sema.errUnknownName(node, text);
                    return null;
                },
            }
        },

        .pointer_type => |p| {
            const child = try sema.resolveType(p.child) orelse return null;
            return try sema.ip.get(sema.gpa, .{
                .pointer = .{ .child = child, .is_mutable = p.is_mutable },
            });
        },
        // An anonymous struct cannot be named, so it cannot be recursive, so its
        // fields are safe to resolve on the spot.
        .struct_type => |fields| {
            if (sema.ip.getIfExists(.{ .struct_type = node })) |existing| return existing;
            const ty = try sema.ip.getStructType(sema.gpa, node, .none, @intCast(fields.len));
            try sema.resolveFields(ty, fields);
            return ty;
        },

        else => {
            try sema.errNotComptime(node, sema.source(node));
            return null;
        },
    }
}

/// One check on top of one evaluation, rather than a second walk over the grammar.
fn resolveType(sema: *Sema, node: Ast.Node.Index) Allocator.Error!?InternPool.Index {
    const value = try sema.evalComptime(node) orelse return null;
    if (!sema.ip.isType(value)) {
        try sema.errExpectedType(node, value);
        return null;
    }
    return value;
}

// Signatures

fn resolveSignatures(sema: *Sema) Allocator.Error!void {
    const tree = sema.tree;
    const decls = sema.decls.slice();

    // Every declaration is an upper bound on the functions among them, which is one
    // allocation instead of a counting pass.
    try sema.fns.ensureTotalCapacity(sema.gpa, decls.len);

    for (decls.items(.kind), decls.items(.node), 0..) |kind, node, i| {
        if (kind != .function) continue;

        const f = tree.full(node).fn_decl;

        const start: u32 = @intCast(sema.params.len);
        try sema.params.ensureUnusedCapacity(sema.gpa, f.params.len);
        for (f.params) |p| {
            const b = tree.full(p).param;
            const name = try sema.ip.getString(sema.gpa, tree.tokenSlice(b.name_token));
            const ty = (try sema.resolveType(b.type_expr)) orelse .type_void;
            sema.params.appendAssumeCapacity(.{ .name = name, .type = ty, .node = p });
        }

        const return_type: InternPool.Index = if (f.return_type.unwrap()) |rt|
            (try sema.resolveType(rt)) orelse .type_void
        else
            .type_void;

        var arena_param: u32 = Fn.no_arena;
        for (sema.params.items(.type)[start..], 0..) |ty, k| {
            if (ty != .type_arena) continue;
            if (arena_param == Fn.no_arena) {
                arena_param = @intCast(k);
                continue;
            }
            try sema.errTooManyArenas(f, arena_param, @intCast(k));
            break; // one report per function, the second arena is the whole story
        }

        sema.fns.appendAssumeCapacity(.{
            .decl = @enumFromInt(i),
            .node = node,
            .params_start = start,
            .params_len = @intCast(f.params.len),
            .return_type = return_type,
            .arena_param = arena_param,
        });
    }
}

// Bodies
//
// Resolution and type checking happen here, while lowering. Every instruction is
// given its type as it is emitted, so a well formed `Ir` is type correct and nothing
// downstream checks types again.

fn lowerBodies(sema: *Sema) Allocator.Error!void {
    try sema.bodies.ensureTotalCapacity(sema.gpa, sema.fns.len);
    for (0..sema.fns.len) |i| {
        sema.bodies.appendAssumeCapacity(try sema.lowerFn(@intCast(i)));
    }
}

fn lowerFn(sema: *Sema, fn_index: u32) Allocator.Error!Ir {
    assert(sema.insts.len == 0 and sema.ir_slots.len == 0 and sema.locals.len == 0);
    sema.block_top = 0;
    sema.current_fn = fn_index;

    const f = sema.fns.get(fn_index);
    const params = sema.params.slice();

    // Parameters are ordinary names, so nothing later has to special case them.
    try sema.locals.ensureUnusedCapacity(sema.gpa, f.params_len);
    for (0..f.params_len) |k| {
        const at = f.params_start + k;
        const node = params.items(.node)[at];
        const ref = try sema.addInst(.{
            .tag = .arg,
            .node = node,
            .type = params.items(.type)[at],
            .data = .{ .index = @intCast(k) },
        });
        sema.locals.appendAssumeCapacity(.{
            .name = params.items(.name)[at],
            .ref = ref,
            .is_slot = false,
            .node = node,
        });
    }

    const body = sema.tree.full(f.node).fn_decl.body;
    try sema.lowerBlock(body);

    // A void function need not write `return`, so a block always ends terminated.
    const tags = sema.insts.items(.tag);
    if (sema.insts.len == 0 or !tags[sema.insts.len - 1].isTerminator()) {
        _ = try sema.addInst(.{
            .tag = .ret,
            .node = body,
            .type = .type_noreturn,
            .data = .{ .opt_un = .none },
        });
    }

    const blocks = try sema.gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .start = 0, .len = @intCast(sema.insts.len) };

    sema.locals.shrinkRetainingCapacity(0);
    return .{
        .instructions = sema.insts.toOwnedSlice(),
        .extra = try sema.ir_extra.toOwnedSlice(sema.gpa),
        .blocks = blocks,
        .slots = sema.ir_slots.toOwnedSlice(),
    };
}

fn addInst(sema: *Sema, inst: Ir.Inst) Allocator.Error!Ir.Inst.Index {
    const i: Ir.Inst.Index = @enumFromInt(sema.insts.len);
    try sema.insts.append(sema.gpa, inst);
    return i;
}

fn addConst(
    sema: *Sema,
    node: Ast.Node.Index,
    ty: InternPool.Index,
    value: InternPool.Index,
) Allocator.Error!Ir.Inst.Index {
    return try sema.addInst(.{ .tag = .constant, .node = node, .type = ty, .data = .{ .value = value } });
}

fn instType(sema: *const Sema, ref: Ir.Inst.Index) InternPool.Index {
    return sema.insts.items(.type)[@intFromEnum(ref)];
}

/// What a pointer points at. Only ever asked of something already known to be one.
fn pointee(sema: *const Sema, ptr: Ir.Inst.Index) InternPool.Index {
    return sema.ip.keyOf(sema.instType(ptr)).pointer.child;
}

/// `*var T` may be read as `*T`, and never the other way. Nothing else converts.
fn coercible(sema: *const Sema, from: InternPool.Index, to: InternPool.Index) bool {
    if (from == to) return true;
    const a = sema.ip.keyOf(from);
    const b = sema.ip.keyOf(to);
    if (a != .pointer or b != .pointer) return false;
    return a.pointer.child == b.pointer.child and a.pointer.is_mutable and !b.pointer.is_mutable;
}

fn lowerBlock(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    const outer_top = sema.block_top;
    const entry: u32 = @intCast(sema.locals.len);
    sema.block_top = entry;
    defer {
        sema.locals.shrinkRetainingCapacity(entry);
        sema.block_top = outer_top;
    }

    for (sema.tree.full(node).block) |stmt| try sema.lowerStmt(stmt);
}

fn lowerStmt(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    switch (sema.tree.full(node)) {
        .var_decl => try sema.lowerVarDecl(node),
        .return_stmt => try sema.lowerReturn(node),
        .assign => try sema.lowerAssign(node),
        .block => try sema.lowerBlock(node),
        else => _ = try sema.lowerExpr(node),
    }
}

fn lowerVarDecl(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    const tree = sema.tree;
    const v = tree.full(node).var_decl;

    const value = try sema.lowerExpr(v.init_expr) orelse return;
    var ty = sema.instType(value);

    if (v.type_expr.unwrap()) |written| {
        if (try sema.resolveType(written)) |declared| {
            if (!sema.coercible(ty, declared)) {
                try sema.errTypeMismatch(v.init_expr, declared, ty);
                return;
            }
            ty = declared;
        }
    }

    const name = try sema.ip.getString(sema.gpa, tree.tokenSlice(v.name_token));
    if (sema.declaredInBlock(name)) |previous| {
        try sema.errDuplicate(v.name_token, previous, "declared again in the same block");
        return;
    }

    // A `let` names a value. Only a `var` needs memory, and therefore a slot.
    if (!v.is_mutable) {
        try sema.locals.append(sema.gpa, .{
            .name = name,
            .ref = value,
            .is_slot = false,
            .node = node,
        });
        return;
    }

    const slot: Ir.Slot.Index = @enumFromInt(sema.ir_slots.len);
    try sema.ir_slots.append(sema.gpa, .{ .name = name, .type = ty, .node = node });

    const ptr = try sema.addInst(.{
        .tag = .slot,
        .node = node,
        .type = try sema.ip.get(sema.gpa, .{ .pointer = .{ .child = ty, .is_mutable = true } }),
        .data = .{ .slot = slot },
    });
    _ = try sema.addInst(.{
        .tag = .store,
        .node = node,
        .type = .type_void,
        .data = .{ .bin = .{ ptr, value } },
    });
    try sema.locals.append(sema.gpa, .{ .name = name, .ref = ptr, .is_slot = true, .node = node });
}

/// Only the innermost block, so shadowing an outer name stays legal.
fn declaredInBlock(sema: *const Sema, name: InternPool.String) ?Ast.Node.Index {
    const names = sema.locals.items(.name);
    var i = sema.locals.len;
    while (i > sema.block_top) {
        i -= 1;
        if (names[i] == name) return sema.locals.items(.node)[i];
    }
    return null;
}

fn lowerReturn(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    const want = sema.fns.items(.return_type)[sema.current_fn];

    if (sema.tree.full(node).return_stmt.unwrap()) |expr| {
        const value = try sema.lowerExpr(expr) orelse return;
        const got = sema.instType(value);
        if (!sema.coercible(got, want)) {
            try sema.errTypeMismatch(expr, want, got);
            return;
        }
        _ = try sema.addInst(.{
            .tag = .ret,
            .node = node,
            .type = .type_noreturn,
            .data = .{ .opt_un = value.toOptional() },
        });
        return;
    }

    if (want != .type_void) {
        try sema.errMissingReturnValue(node, want);
        return;
    }
    _ = try sema.addInst(.{
        .tag = .ret,
        .node = node,
        .type = .type_noreturn,
        .data = .{ .opt_un = .none },
    });
}

fn lowerAssign(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    const a = sema.tree.full(node).assign;
    const ptr = try sema.lowerPlace(a.lhs) orelse return;
    const value = try sema.lowerExpr(a.rhs) orelse return;

    const want = sema.pointee(ptr);
    const got = sema.instType(value);
    if (!sema.coercible(got, want)) {
        try sema.errTypeMismatch(a.rhs, want, got);
        return;
    }
    _ = try sema.addInst(.{
        .tag = .store,
        .node = node,
        .type = .type_void,
        .data = .{ .bin = .{ ptr, value } },
    });
}

/// An assignable location, lowered to the pointer that names it.
fn lowerPlace(sema: *Sema, node: Ast.Node.Index) Allocator.Error!?Ir.Inst.Index {
    switch (sema.tree.full(node)) {
        .ident => |token| {
            const text = sema.tree.tokenSlice(token);
            switch (try sema.lookup(text)) {
                .local => |i| {
                    if (sema.locals.items(.is_slot)[i]) return sema.locals.items(.ref)[i];
                    try sema.errNotAssignable(node, text);
                    return null;
                },
                .not_found => {
                    try sema.errUnknownName(node, text);
                    return null;
                },
                else => {
                    try sema.errNotAssignable(node, text);
                    return null;
                },
            }
        },
        .field_access => return sema.lowerFieldPtr(node),
        else => {
            try sema.errNotAPlace(node);
            return null;
        },
    }
}

fn lowerFieldPtr(sema: *Sema, node: Ast.Node.Index) Allocator.Error!?Ir.Inst.Index {
    const tree = sema.tree;
    const access = tree.full(node).field_access;

    const base = try sema.lowerExpr(access.lhs) orelse return null;
    const base_type = sema.instType(base);

    // A field is reached through a pointer. Taking one of a struct value would mean
    // materializing a temporary, which no test needs and which the region pass would
    // have to be taught about first.
    const key = sema.ip.keyOf(base_type);
    if (key != .pointer or sema.ip.keyOf(key.pointer.child) != .struct_type) {
        try sema.errNoFields(access.lhs, base_type);
        return null;
    }

    const struct_type = key.pointer.child;
    const text = tree.tokenSlice(access.name_token);
    const name = try sema.ip.getString(sema.gpa, text);
    const index = sema.ip.fieldIndex(struct_type, name) orelse {
        try sema.errNoField(access.name_token, struct_type, text);
        return null;
    };

    return try sema.addInst(.{
        .tag = .field_ptr,
        .node = node,
        .type = try sema.ip.get(sema.gpa, .{ .pointer = .{
            .child = sema.ip.structFields(struct_type)[index].type,
            // Reading through `*T` yields `*T`, so a field cannot be written through
            // a pointer that could not be written through itself.
            .is_mutable = key.pointer.is_mutable,
        } }),
        .data = .{ .field = .{ .base = base, .index = index } },
    });
}

fn lowerExpr(sema: *Sema, node: Ast.Node.Index) Allocator.Error!?Ir.Inst.Index {
    const tree = sema.tree;
    switch (tree.full(node)) {
        .grouped => |child| return sema.lowerExpr(child),

        // Anything with no runtime part is evaluated, not lowered twice.
        .int_literal, .str_literal, .bool_literal, .pointer_type, .struct_type => {
            const value = try sema.evalComptime(node) orelse return null;
            return try sema.addConst(node, sema.ip.typeOf(value), value);
        },

        .ident => |token| {
            const resolved = try sema.lookup(tree.tokenSlice(token));
            if (resolved == .local) {
                const ref = sema.locals.items(.ref)[resolved.local];
                if (!sema.locals.items(.is_slot)[resolved.local]) return ref;
                return try sema.addInst(.{
                    .tag = .load,
                    .node = node,
                    .type = sema.pointee(ref),
                    .data = .{ .un = ref },
                });
            }
            // A local is the only thing a name can mean at runtime. Everything else
            // it can mean is a constant, including a type.
            const value = try sema.evalComptime(node) orelse return null;
            return try sema.addConst(node, sema.ip.typeOf(value), value);
        },

        .field_access => {
            const ptr = try sema.lowerFieldPtr(node) orelse return null;
            return try sema.addInst(.{
                .tag = .load,
                .node = node,
                .type = sema.pointee(ptr),
                .data = .{ .un = ptr },
            });
        },

        .binary => |b| {
            const lhs = try sema.lowerExpr(b.lhs) orelse return null;
            const rhs = try sema.lowerExpr(b.rhs) orelse return null;
            const lt = sema.instType(lhs);
            const rt = sema.instType(rhs);
            if (lt != rt) {
                try sema.errBinaryMismatch(node, b.op_token, lt, rt);
                return null;
            }

            const want: InternPool.Index, const result: InternPool.Index = switch (b.op) {
                .add, .sub, .mul, .div, .mod => .{ .type_i64, .type_i64 },
                .bool_and, .bool_or => .{ .type_bool, .type_bool },
                .equal, .not_equal => .{ lt, .type_bool },
                .less_than, .less_or_equal, .greater_than, .greater_or_equal => .{ .type_i64, .type_bool },
            };
            if (lt != want) {
                try sema.errBadOperand(node, b.op_token, want, lt);
                return null;
            }

            return try sema.addInst(.{
                .tag = switch (b.op) {
                    inline else => |op| @field(Ir.Inst.Tag, @tagName(op)),
                },
                .node = node,
                .type = result,
                .data = .{ .bin = .{ lhs, rhs } },
            });
        },

        .unary => |u| {
            const operand = try sema.lowerExpr(u.operand) orelse return null;
            const got = sema.instType(operand);
            const want: InternPool.Index = switch (u.op) {
                .negate => .type_i64,
                .bool_not => .type_bool,
            };
            if (got != want) {
                try sema.errBadOperand(node, u.op_token, want, got);
                return null;
            }
            return try sema.addInst(.{
                .tag = switch (u.op) {
                    inline else => |op| @field(Ir.Inst.Tag, @tagName(op)),
                },
                .node = node,
                .type = want,
                .data = .{ .un = operand },
            });
        },

        .call => return sema.lowerCall(node),

        else => {
            try sema.errNotAnExpr(node);
            return null;
        },
    }
}

fn lowerCall(sema: *Sema, node: Ast.Node.Index) Allocator.Error!?Ir.Inst.Index {
    const tree = sema.tree;
    const call = tree.full(node).call;

    if (tree.nodeTag(call.callee) == .field_access) return sema.lowerMethodCall(node, call);

    if (tree.nodeTag(call.callee) != .ident) {
        try sema.errNotCallable(call.callee);
        return null;
    }
    const text = tree.tokenSlice(tree.full(call.callee).ident);

    const resolved = try sema.lookup(text);
    if (resolved != .decl or sema.decls.items(.kind)[@intFromEnum(resolved.decl)] != .function) {
        if (resolved == .not_found) {
            try sema.errUnknownName(call.callee, text);
        } else {
            try sema.errNotCallable(call.callee);
        }
        return null;
    }

    const fn_index = sema.fnOfDecl(resolved.decl).?;
    const f = sema.fns.get(fn_index);
    if (call.args.len != f.params_len) {
        try sema.errArity(node, text, f.params_len, @intCast(call.args.len));
        return null;
    }

    // Reserved first so a nested call cannot interleave into this one's payload.
    const at: u32 = @intCast(sema.ir_extra.items.len);
    try sema.ir_extra.appendNTimes(sema.gpa, 0, Ir.Call.len + call.args.len);
    sema.ir_extra.items[at] = fn_index;
    sema.ir_extra.items[at + 1] = @intCast(call.args.len);

    for (call.args, 0..) |arg, k| {
        const value = try sema.lowerExpr(arg) orelse return null;
        const want = sema.params.items(.type)[f.params_start + k];
        const got = sema.instType(value);
        if (!sema.coercible(got, want)) {
            try sema.errTypeMismatch(arg, want, got);
            return null;
        }
        sema.ir_extra.items[at + Ir.Call.len + k] = @intFromEnum(value);
    }

    return try sema.addInst(.{
        .tag = .call,
        .node = node,
        .type = f.return_type,
        .data = .{ .payload = @enumFromInt(at) },
    });
}

fn fnOfDecl(sema: *const Sema, decl: Decl.Index) ?u32 {
    for (sema.fns.items(.decl), 0..) |d, i| {
        if (d == decl) return @intCast(i);
    }
    return null;
}

/// The arena vocabulary. These are the operations the region pass has to see, so each
/// becomes its own instruction rather than an ordinary call.
fn lowerMethodCall(sema: *Sema, node: Ast.Node.Index, call: Ast.Full.Call) Allocator.Error!?Ir.Inst.Index {
    const tree = sema.tree;
    const access = tree.full(call.callee).field_access;
    const method = tree.tokenSlice(access.name_token);

    const recv = try sema.lowerExpr(access.lhs) orelse return null;
    const recv_type = sema.instType(recv);

    // `Arena.init()`, called on the type rather than on a value.
    if (recv_type == .type_type) {
        if (sema.constValue(recv) == .type_arena and std.mem.eql(u8, method, "init")) {
            if (call.args.len != 0) {
                try sema.errArity(node, "Arena.init", 0, @intCast(call.args.len));
                return null;
            }
            return try sema.addInst(.{
                .tag = .arena_init,
                .node = node,
                .type = .type_arena,
                .data = .{ .none = {} },
            });
        }
        try sema.errNoMethod(access.name_token, recv_type, method);
        return null;
    }

    if (recv_type != .type_arena) {
        try sema.errNoMethod(access.name_token, recv_type, method);
        return null;
    }

    const op = std.meta.stringToEnum(ArenaOp, method) orelse {
        try sema.errNoMethod(access.name_token, recv_type, method);
        return null;
    };

    const wants: usize = switch (op) {
        .create, .copy => 1,
        .child, .reset => 0,
    };
    if (call.args.len != wants) {
        try sema.errArity(node, method, @intCast(wants), @intCast(call.args.len));
        return null;
    }

    switch (op) {
        .child => return try sema.addInst(.{
            .tag = .arena_child,
            .node = node,
            .type = .type_arena,
            .data = .{ .un = recv },
        }),
        .reset => return try sema.addInst(.{
            .tag = .arena_reset,
            .node = node,
            .type = .type_void,
            .data = .{ .un = recv },
        }),
        .create => {
            const arg = try sema.lowerExpr(call.args[0]) orelse return null;
            if (sema.instType(arg) != .type_type) {
                try sema.errTypeMismatch(call.args[0], .type_type, sema.instType(arg));
                return null;
            }
            return try sema.addInst(.{
                .tag = .arena_create,
                .node = node,
                // Fresh memory is writable. Weakening to `*T` is the caller's to do.
                .type = try sema.ip.get(sema.gpa, .{ .pointer = .{
                    .child = sema.constValue(arg),
                    .is_mutable = true,
                } }),
                .data = .{ .un = recv },
            });
        },
        .copy => {
            const arg = try sema.lowerExpr(call.args[0]) orelse return null;
            const ty = sema.instType(arg);
            // The one memory rule a signature settles: `copy` takes a pointer free type.
            if (!sema.ip.isPointerFree(ty)) {
                try sema.errCopyHoldsPointer(node, call.args[0], access.lhs, ty);
                return null;
            }
            return try sema.addInst(.{
                .tag = .arena_copy,
                .node = node,
                .type = ty,
                .data = .{ .bin = .{ recv, arg } },
            });
        },
    }
}

const ArenaOp = enum { child, create, copy, reset };

/// The value a `constant` instruction carries. Only ever asked of one.
fn constValue(sema: *const Sema, ref: Ir.Inst.Index) InternPool.Index {
    assert(sema.insts.items(.tag)[@intFromEnum(ref)] == .constant);
    return sema.insts.items(.data)[@intFromEnum(ref)].value;
}



// Diagnostics

fn label(
    span: Ast.Span,
    style: Diagnostic.Label.Style,
    text: []const u8,
) Diagnostic.Label {
    return .{ .start = span.start, .end = span.end, .style = style, .text = text };
}

/// The token a declaration is named by, so a diagnostic points at the name rather
/// than at the `fn` or `let` in front of it.
fn declNameToken(tree: Ast, node: Ast.Node.Index) Ast.TokenIndex {
    return switch (tree.full(node)) {
        .fn_decl => |f| f.name_token,
        .var_decl => |v| v.name_token,
        else => tree.firstToken(node),
    };
}

fn errTooManyArenas(sema: *Sema, f: Ast.Full.FnDecl, first: u32, second: u32) Allocator.Error!void {
    @branchHint(.cold);
    const tree = sema.tree;
    const arena = sema.arena;

    const fn_name = tree.tokenSlice(f.name_token);
    const first_name = tree.tokenSlice(tree.full(f.params[first]).param.name_token);
    const second_name = tree.tokenSlice(tree.full(f.params[second]).param.name_token);

    var labels: std.ArrayList(Diagnostic.Label) = .empty;
    try labels.append(arena, label(tree.nodeSpan(f.params[first]), .secondary, "the first arena parameter"));
    try labels.append(arena, label(tree.nodeSpan(f.params[second]), .primary, "a second arena parameter"));
    if (f.return_type.unwrap()) |rt| {
        try labels.append(arena, label(tree.nodeSpan(rt), .secondary, "which arena is this in?"));
    }

    // The suggestion is the signature already written, with the second arena taken
    // out and turned into the child it should have been.
    var code: std.ArrayList(u8) = .empty;
    try code.print(arena, "fn {s}(", .{fn_name});
    var written: usize = 0;
    for (f.params, 0..) |p, i| {
        if (i == second) continue;
        if (written > 0) try code.appendSlice(arena, ", ");
        const span = tree.nodeSpan(p);
        try code.appendSlice(arena, tree.source[span.start..span.end]);
        written += 1;
    }
    try code.appendSlice(arena, ")");
    if (f.return_type.unwrap()) |rt| {
        const span = tree.nodeSpan(rt);
        try code.print(arena, " {s}", .{tree.source[span.start..span.end]});
    }
    try code.print(arena, " {{\n    var {s} = {s}.child()", .{ second_name, first_name });

    try sema.diagnostics.append(sema.gpa, .{
        .message = try std.fmt.allocPrint(
            arena,
            "'{s}' takes more than one arena, so its result has no single home",
            .{fn_name},
        ),
        .labels = try labels.toOwnedSlice(arena),
        .notes = try arena.dupe(Diagnostic.Note, &.{
            .{
                .kind = .note,
                .text =
                \\A function allocates its results into exactly one arena. That rule
                \\is what lets a caller know where a result lives without anyone
                \\writing a lifetime down.
                ,
            },
            .{
                .kind = .help,
                .text = try std.fmt.allocPrint(
                    arena,
                    "drop '{s}', and create a child inside the body for temporaries",
                    .{second_name},
                ),
                .code = try code.toOwnedSlice(arena),
            },
        }),
    });
}

fn errDuplicate(
    sema: *Sema,
    token: Ast.TokenIndex,
    previous: Ast.Node.Index,
    again: []const u8,
) Allocator.Error!void {
    @branchHint(.cold);
    const tree = sema.tree;
    const labels = try sema.arena.dupe(Diagnostic.Label, &.{
        label(tree.tokenSpan(declNameToken(tree, previous)), .secondary, "the first one is here"),
        label(tree.tokenSpan(token), .primary, again),
    });
    try sema.diagnostics.append(sema.gpa, .{
        .message = try std.fmt.allocPrint(sema.arena, "'{s}' is declared twice", .{tree.tokenSlice(token)}),
        .labels = labels,
    });
}

fn errShadowsBuiltin(sema: *Sema, token: Ast.TokenIndex, text: []const u8) Allocator.Error!void {
    @branchHint(.cold);
    const labels = try sema.arena.dupe(Diagnostic.Label, &.{
        label(sema.tree.tokenSpan(token), .primary, "this name belongs to the language"),
    });
    try sema.diagnostics.append(sema.gpa, .{
        .message = try std.fmt.allocPrint(sema.arena, "'{s}' is a built-in type name", .{text}),
        .labels = labels,
    });
}

fn errExpectedType(
    sema: *Sema,
    node: Ast.Node.Index,
    got: InternPool.Index,
) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        "expected a type",
        try std.fmt.allocPrint(sema.arena, "this is a '{s}'", .{try sema.typeName(sema.ip.typeOf(got))}),
    );
}

fn errNotComptime(sema: *Sema, node: Ast.Node.Index, text: []const u8) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "'{s}' is not known at compile time", .{text}),
        "needed here before the program runs",
    );
}

fn errCycle(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(node, "this declaration depends on itself", "it cannot be resolved");
}

fn errUnknownName(sema: *Sema, node: Ast.Node.Index, text: []const u8) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "cannot find '{s}' in this scope", .{text}),
        "not declared anywhere in this file",
    );
}



fn oneLabel(
    sema: *Sema,
    node: Ast.Node.Index,
    message: []const u8,
    text: []const u8,
) Allocator.Error!void {
    const labels = try sema.arena.dupe(Diagnostic.Label, &.{
        label(sema.tree.nodeSpan(node), .primary, text),
    });
    try sema.diagnostics.append(sema.gpa, .{ .message = message, .labels = labels });
}

/// A type as a programmer would write it. Long ones truncate, which only ever
/// affects a message.
fn typeName(sema: *Sema, ty: InternPool.Index) Allocator.Error![]const u8 {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    sema.ip.printType(ty, &w) catch {};
    return sema.arena.dupe(u8, w.buffered());
}

fn source(sema: *const Sema, node: Ast.Node.Index) []const u8 {
    const span = sema.tree.nodeSpan(node);
    return sema.tree.source[span.start..span.end];
}

fn errTypeMismatch(
    sema: *Sema,
    node: Ast.Node.Index,
    want: InternPool.Index,
    got: InternPool.Index,
) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "expected '{s}', found '{s}'", .{
            try sema.typeName(want),
            try sema.typeName(got),
        }),
        try std.fmt.allocPrint(sema.arena, "this is a '{s}'", .{try sema.typeName(got)}),
    );
}

fn errBinaryMismatch(
    sema: *Sema,
    node: Ast.Node.Index,
    op: Ast.TokenIndex,
    lhs: InternPool.Index,
    rhs: InternPool.Index,
) Allocator.Error!void {
    @branchHint(.cold);
    const labels = try sema.arena.dupe(Diagnostic.Label, &.{
        label(sema.tree.nodeSpan(node), .primary, "the two sides have different types"),
        label(sema.tree.tokenSpan(op), .secondary, "applied here"),
    });
    try sema.diagnostics.append(sema.gpa, .{
        .message = try std.fmt.allocPrint(sema.arena, "cannot apply '{s}' to '{s}' and '{s}'", .{
            sema.tree.tokenSlice(op),
            try sema.typeName(lhs),
            try sema.typeName(rhs),
        }),
        .labels = labels,
    });
}

fn errBadOperand(
    sema: *Sema,
    node: Ast.Node.Index,
    op: Ast.TokenIndex,
    want: InternPool.Index,
    got: InternPool.Index,
) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "'{s}' needs '{s}', found '{s}'", .{
            sema.tree.tokenSlice(op),
            try sema.typeName(want),
            try sema.typeName(got),
        }),
        "this operand has the wrong type",
    );
}

fn errMissingReturnValue(
    sema: *Sema,
    node: Ast.Node.Index,
    want: InternPool.Index,
) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "this function returns '{s}'", .{try sema.typeName(want)}),
        "nothing is returned here",
    );
}

fn errNotAssignable(sema: *Sema, node: Ast.Node.Index, text: []const u8) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "cannot assign to '{s}'", .{text}),
        "this name is not a 'var'",
    );
}

fn errNotAPlace(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(node, "cannot assign to this expression", "not something that holds a value");
}

fn errNoFields(sema: *Sema, node: Ast.Node.Index, ty: InternPool.Index) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "'{s}' has no fields to reach through", .{try sema.typeName(ty)}),
        "a field is reached through a pointer to a struct",
    );
}

fn errNoField(
    sema: *Sema,
    token: Ast.TokenIndex,
    struct_type: InternPool.Index,
    text: []const u8,
) Allocator.Error!void {
    @branchHint(.cold);
    const labels = try sema.arena.dupe(Diagnostic.Label, &.{
        label(sema.tree.tokenSpan(token), .primary, "no field with this name"),
    });
    try sema.diagnostics.append(sema.gpa, .{
        .message = try std.fmt.allocPrint(sema.arena, "'{s}' has no field '{s}'", .{
            try sema.typeName(struct_type),
            text,
        }),
        .labels = labels,
    });
}

fn errNoMethod(
    sema: *Sema,
    token: Ast.TokenIndex,
    ty: InternPool.Index,
    method: []const u8,
) Allocator.Error!void {
    @branchHint(.cold);
    const labels = try sema.arena.dupe(Diagnostic.Label, &.{
        label(sema.tree.tokenSpan(token), .primary, "not an operation on this type"),
    });
    try sema.diagnostics.append(sema.gpa, .{
        .message = try std.fmt.allocPrint(sema.arena, "'{s}' has no '{s}'", .{
            try sema.typeName(ty),
            method,
        }),
        .labels = labels,
    });
}

fn errNotCallable(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(node, "this is not a function", "cannot be called");
}

fn errArity(
    sema: *Sema,
    node: Ast.Node.Index,
    name: []const u8,
    want: u32,
    got: u32,
) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "'{s}' takes {d} argument{s}, found {d}", .{
            name,
            want,
            if (want == 1) "" else "s",
            got,
        }),
        try std.fmt.allocPrint(sema.arena, "{d} given here", .{got}),
    );
}

fn errBadInt(sema: *Sema, node: Ast.Node.Index, text: []const u8) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(
        node,
        try std.fmt.allocPrint(sema.arena, "'{s}' is not a number this compiler can hold", .{text}),
        "does not fit in an 'i64'",
    );
}


fn errNotAnExpr(sema: *Sema, node: Ast.Node.Index) Allocator.Error!void {
    @branchHint(.cold);
    try sema.oneLabel(node, "expected a value", "this does not produce one");
}

/// `copy` relabels a value as living somewhere new without touching what its pointers
/// reach, so the type it is given has to own everything inside it.
fn errCopyHoldsPointer(
    sema: *Sema,
    call_node: Ast.Node.Index,
    arg_node: Ast.Node.Index,
    recv_node: Ast.Node.Index,
    ty: InternPool.Index,
) Allocator.Error!void {
    @branchHint(.cold);
    const tree = sema.tree;
    const ip = sema.ip;
    const arena = sema.arena;

    const type_name = try sema.typeName(ty);
    const recv = sema.source(recv_node);

    if (ip.keyOf(ty) != .struct_type) {
        try sema.oneLabel(
            call_node,
            try std.fmt.allocPrint(arena, "'{s}' cannot be copied between arenas", .{type_name}),
            "this type does not own what it reaches",
        );
        return;
    }

    const fields = ip.structFields(ty);
    const field_nodes = tree.full(ip.keyOf(ty).struct_type).struct_type;

    var culprit: u32 = 0;
    for (fields, 0..) |f, i| {
        if (!ip.isPointerFree(f.type)) {
            culprit = @intCast(i);
            break;
        }
    }
    const culprit_name = ip.stringSlice(fields[culprit].name);
    const culprit_type = tree.full(field_nodes[culprit]).field.type_expr;

    var labels: std.ArrayList(Diagnostic.Label) = .empty;
    try labels.append(arena, label(
        tree.nodeSpan(culprit_type),
        .secondary,
        try std.fmt.allocPrint(arena, "'{s}' holds a pointer here", .{type_name}),
    ));
    try labels.append(arena, label(
        tree.nodeSpan(call_node),
        .primary,
        try std.fmt.allocPrint(arena, "this moves the struct, not what '{s}' points at", .{culprit_name}),
    ));

    // The fix is the struct rebuilt one field at a time, with whatever the pointer
    // reaches copied first.
    var code: std.ArrayList(u8) = .empty;
    try code.print(arena, "var q = {s}.create({s})", .{ recv, type_name });
    for (fields) |f| {
        const name = ip.stringSlice(f.name);
        if (ip.isPointerFree(f.type)) {
            try code.print(arena, "\nq.{s} = {s}.{s}", .{ name, sema.source(arg_node), name });
            continue;
        }
        const inner = ip.keyOf(f.type).pointer.child;
        try code.print(arena, "\nq.{s} = {s}.create({s})", .{ name, recv, try sema.typeName(inner) });
        if (ip.keyOf(inner) == .struct_type) {
            for (ip.structFields(inner)) |g| {
                const sub = ip.stringSlice(g.name);
                try code.print(arena, "\nq.{s}.{s} = {s}.{s}.{s}", .{
                    name, sub, sema.source(arg_node), name, sub,
                });
            }
        }
    }

    try sema.diagnostics.append(sema.gpa, .{
        .message = try std.fmt.allocPrint(arena, "'{s}' cannot be copied between arenas", .{type_name}),
        .labels = try labels.toOwnedSlice(arena),
        .notes = try arena.dupe(Diagnostic.Note, &.{
            .{
                .kind = .note,
                .text = try std.fmt.allocPrint(
                    arena,
                    "a copy moves the bytes a value owns directly. A pointer inside would\nkeep pointing into the old arena, so the copy would live in '{s}'\nwhile '{s}' did not.",
                    .{ recv, culprit_name },
                ),
            },
            .{
                .kind = .help,
                .text = "copy what the pointer reaches, and rebuild the struct around it",
                .code = try code.toOwnedSlice(arena),
            },
        }),
    });
}
