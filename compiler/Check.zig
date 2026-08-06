//! Type check the AST, lowering function bodies to IR.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Compilation = @import("Compilation.zig");
const IR = @import("IR.zig");
const Module = @import("Module.zig");
const Pool = @import("Pool.zig");
const Intrinsic = @import("Intrinsic.zig").Intrinsic;
const intrinsic_limits = @import("Intrinsic.zig");
const Token = @import("Token.zig");
const edit_distance = @import("util/edit_distance.zig");

const Decl = Module.Decl;
const Node = AST.Node;
const Ref = IR.Ref;

comp: *Compilation,
module_index: Module.Index,
module: *Module,
tree: *const AST,
/// The type parameters in scope, substituted for the whole unit.
bindings: []const Binding,
/// Null means constants only.
builder: ?*Builder,
/// Field types skip the embedding demand, because their struct gets its own walk.
demand_embedding: bool,

const Check = @This();

const type_params_max = AST.type_params_max;
const bindings_max = type_params_max * 2;
const call_args_max = 255;
const type_depth_max = AST.nest_max;

const Binding = struct { name: Pool.String, type: Pool.Index };

/// What an expression turned out to be. A `named_` case is not a value, and is legal
/// only where its comment says.
const Value = union(enum) {
    constant: Pool.Index,
    runtime: Runtime,
    /// No value, no diagnostic owed. `poison` is the same after one.
    diverged,
    poison,
    /// `Point` in `Point.zero()`.
    named_type: Pool.Index,
    /// `Box` in `Box[i64]`, awaiting arguments.
    named_generic: Decl.Index,
    /// `helper` in `helper(1)`.
    named_fn: Decl.Index,
    /// `std` in `std.mem`.
    named_module: Module.Index,
    /// `intrinsic` in `intrinsic.ptr_cast[T](p)`.
    named_intrinsic,

    const Runtime = struct { ref: Ref, type: Pool.Index };

    /// A void result. Callers read the type, never the ref.
    const void_value: Value = .{ .runtime = .{ .ref = .fromConstant(.poison), .type = .void_type } };
};

// entry points, one per unit kind `ensure` dispatches

pub fn typeAlias(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    var check = context(comp, decl_index, &.{});
    const view = check.tree.viewOf(check.declNode(decl_index)).alias_decl;

    const resolved = try check.resolveWrittenType(view.aliased);
    comp.declPtr(decl_index).result = resolved.int();
    return resolved != .poison;
}

pub fn topLevelLet(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    var check = context(comp, decl_index, &.{});
    const view = check.tree.viewOf(check.declNode(decl_index)).var_decl;
    assert(view.is_mutable == false);

    const value = try check.checkExpr(view.init_expr, null);
    const constant = switch (value) {
        .constant => |index| index,
        .poison => Pool.Index.poison,
        .runtime => unreachable,
        else => other: {
            try check.reportNotValue(view.init_expr, value);
            break :other Pool.Index.poison;
        },
    };

    var met = constant;
    if (view.type_expr.unwrap()) |type_expr| {
        const annotation = try check.resolveType(type_expr);
        met = try check.fitConstant(constant, annotation, view.init_expr);
    }

    comp.declPtr(decl_index).result = met.int();
    return met != .poison;
}

/// Fields into rows, with the type parameters bound to this instantiation.
pub fn structRows(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    var buffer: [bindings_max]Binding = undefined;
    const bindings = try bindTypeParams(comp, instance, &buffer);
    var check = context(comp, decl_index, bindings);
    check.demand_embedding = false;

    const view = check.tree.viewOf(check.declNode(decl_index)).struct_decl;

    // staged, because resolving a field type can build other rows
    const mark = comp.rows_scratch.items.len;
    defer comp.rows_scratch.shrinkRetainingCapacity(mark);

    var clean = true;
    for (view.members) |member| {
        if (check.tree.nodeTag(member) != .field) continue;
        const field = check.tree.viewOf(member).field;

        const field_type = try check.resolveType(field.type_expr);
        if (field_type == .poison) clean = false;
        try comp.rows_scratch.append(comp.gpa, .{
            .name = try comp.pool.string(comp.gpa, check.tree.tokenSlice(field.name_token)),
            .type = field_type,
            .node = member,
        });
    }

    try commitRows(comp, instance, mark);
    return clean;
}

fn commitRows(comp: *Compilation, instance: Pool.Instance, mark: usize) Allocator.Error!void {
    const staged = comp.rows_scratch.items[mark..];
    if (comp.rows.items.len + staged.len > std.math.maxInt(u32)) return error.OutOfMemory;

    const rows_start: u32 = @intCast(comp.rows.items.len);
    try comp.rows.appendSlice(comp.gpa, staged);
    comp.instancePtr(instance).rows = .{ .start = rows_start, .len = @intCast(staged.len) };
}

/// What a struct embeds by value. A cycle means no size, which `ensure` reports.
pub fn structEmbedding(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    const decl = comp.declAt(decl_index);
    const from: Compilation.Origin = .{ .module = decl.module, .node = decl.node };
    try comp.ensure(.of(.rows, instance), from);

    const rows = comp.instanceAt(instance).rows;
    for (rows.start..rows.end()) |raw| {
        // by index, because the walk can grow the rows table
        const row = comp.rowAt(@intCast(raw));
        try walkEmbedded(comp, row.type, .{ .module = decl.module, .node = row.node }, 0);
    }
    return true;
}

/// The types a value embeds directly. A pointer breaks the chain.
fn walkEmbedded(
    comp: *Compilation,
    type_index: Pool.Index,
    from: Compilation.Origin,
    depth: u32,
) Allocator.Error!void {
    if (depth >= type_depth_max) return;
    switch (comp.pool.keyOf(type_index)) {
        .type_struct => |embedded| try comp.ensure(.of(.embedding, embedded), from),
        .type_union => {
            // a union holds one member in place, so every member embeds.
            // by position, because the demand can grow the pool
            const count = comp.pool.unionMemberCount(type_index);
            var at: u32 = 0;
            while (at < count) : (at += 1) {
                const member = comp.pool.unionMemberAt(type_index, at);
                try walkEmbedded(comp, member, from, depth + 1);
            }
        },
        .type_simple, .type_unit, .value_simple, .type_pointer => {},
        .value_int, .value_float, .value_unit => unreachable,
    }
}

pub fn fnSignature(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    var buffer: [bindings_max]Binding = undefined;
    const bindings = try bindTypeParams(comp, instance, &buffer);
    var check = context(comp, decl_index, bindings);

    const view = check.tree.viewOf(check.declNode(decl_index)).fn_decl;

    // staged, because resolving a parameter type can build other rows
    const mark = comp.rows_scratch.items.len;
    defer comp.rows_scratch.shrinkRetainingCapacity(mark);

    var clean = true;
    for (view.params) |param_node| {
        if (check.tree.nodeTag(param_node) != .param) continue;
        const param = check.tree.viewOf(param_node).param;
        const name_text = check.tree.tokenSlice(param.name_token);

        const param_type = try check.resolveWrittenType(param.type_expr);
        if (param_type == .poison) clean = false;

        for (comp.rows_scratch.items[mark..]) |earlier| {
            if (std.mem.eql(u8, comp.pool.stringText(earlier.name), name_text)) {
                try check.fail(param_node, .{
                    .code = .redeclared,
                    .message = try comp.fmt("'{s}' is already a parameter", .{name_text}),
                    .label = "declared again here",
                    .notes = try comp.notes(&.{
                        comp.noteAt(check.module_index, earlier.node, "first declared here"),
                    }),
                });
                clean = false;
                break;
            }
        }

        try comp.rows_scratch.append(comp.gpa, .{
            .name = try comp.pool.string(comp.gpa, name_text),
            .type = param_type,
            .node = param_node,
        });
    }

    try commitRows(comp, instance, mark);

    const return_type: Pool.Index = if (view.return_type.unwrap()) |type_expr|
        try check.resolveWrittenType(type_expr)
    else
        .void_type;
    comp.instancePtr(instance).type = return_type;

    if (return_type == .poison) clean = false;
    return clean;
}

/// Arguments to type parameters, the owner first for a member.
fn bindTypeParams(
    comp: *Compilation,
    instance: Pool.Instance,
    buffer: *[bindings_max]Binding,
) Allocator.Error![]const Binding {
    const decl_index = comp.instanceDecl(instance);
    const decl = comp.declAt(decl_index);
    const args = comp.instanceArgs(instance);
    const tree = comp.treeOf(decl.module);

    var count: u32 = 0;
    if (decl.owner.unwrap()) |owner_index| {
        const owner = comp.declAt(owner_index);
        const owner_view = tree.viewOf(owner.node).struct_decl;
        assert(owner_view.type_params.len <= type_params_max);
        for (owner_view.type_params) |param| {
            assert(count < buffer.len);
            buffer[count] = .{
                .name = try comp.pool.string(comp.gpa, tree.tokenSlice(tree.nodeMainToken(param))),
                .type = args[count],
            };
            count += 1;
        }
    }

    const own = switch (tree.viewOf(decl.node)) {
        .struct_decl => |view| view.type_params,
        .fn_decl => |view| view.type_params,
        else => unreachable,
    };
    assert(own.len <= type_params_max);
    for (own) |param| {
        assert(count < buffer.len);
        buffer[count] = .{
            .name = try comp.pool.string(comp.gpa, tree.tokenSlice(tree.nodeMainToken(param))),
            .type = args[count],
        };
        count += 1;
    }

    assert(count == args.len);
    return buffer[0..count];
}

fn context(comp: *Compilation, decl_index: Decl.Index, bindings: []const Binding) Check {
    const decl = comp.declAt(decl_index);
    const module = comp.moduleAt(decl.module);
    assert(module.failed == false);
    return .{
        .comp = comp,
        .module_index = decl.module,
        .module = module,
        .tree = &module.tree,
        .bindings = bindings,
        .builder = null,
        .demand_embedding = true,
    };
}

fn declNode(check: *const Check, decl_index: Decl.Index) Node.Index {
    const decl = check.comp.declAt(decl_index);
    assert(decl.module == check.module_index);
    return decl.node;
}

// type expressions, where the type grammar meets the pool

/// A written type promises storage, so what it embeds must have a size.
fn resolveWrittenType(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const resolved = try check.resolveType(node);
    if (check.demand_embedding and resolved != .poison) {
        try walkEmbedded(check.comp, resolved, check.origin(node), 0);
    }
    return resolved;
}

fn resolveType(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    switch (check.tree.viewOf(node)) {
        .ident => return check.resolveTypeName(node),
        .field_access => |access| {
            const base = try check.checkExpr(access.lhs, null);
            switch (base) {
                .named_module => |target| {
                    const member = try check.moduleMember(target, node, access.name_token) orelse
                        return .poison;
                    return check.declAsType(member, node);
                },
                .poison => return .poison,
                else => {
                    try check.fail(node, .{
                        .code = .not_a_type,
                        .message = "only a module reaches a type with '.'",
                        .label = "not a type",
                    });
                    return .poison;
                },
            }
        },
        .bracket => return check.resolveBracketType(node),
        .pointer_type => |pointer| {
            const child = try check.resolveType(pointer.child);
            if (child == .poison) return .poison;
            return check.pointerTo(child, pointer.is_mutable);
        },
        .union_type => |members| return check.resolveUnionType(node, members),
        .err => return .poison,
        // a bracket item arrives as an expression until its base says otherwise
        else => {
            try check.fail(node, .{
                .code = .not_a_type,
                .message = "this is a value, and a type belongs here",
                .label = "not a type",
            });
            return .poison;
        },
    }
}

fn pointerTo(check: *Check, child: Pool.Index, mutable: bool) Allocator.Error!Pool.Index {
    const comp = check.comp;
    return comp.pool.intern(comp.gpa, .{ .type_pointer = .{ .child = child, .mutable = mutable } });
}

fn resolveUnionType(
    check: *Check,
    node: Node.Index,
    members: []const Node.Index,
) Allocator.Error!Pool.Index {
    const comp = check.comp;
    assert(members.len >= 2);

    if (members.len > Pool.union_members_max) {
        try check.failTooWide(node);
        return .poison;
    }

    var buffer: [Pool.union_members_max]Pool.Index = undefined;
    var clean = true;
    for (members, 0..) |member, at| {
        const resolved = try check.resolveType(member);
        if (resolved == .poison) clean = false;
        buffer[at] = resolved;
    }
    if (clean == false) return .poison;

    switch (try comp.pool.unite(comp.gpa, buffer[0..members.len])) {
        .index => |index| return index,
        .duplicate => |repeat| {
            // the caret prefers the member written twice over the whole union
            var where = node;
            for (members, 0..) |member, at| {
                if (buffer[at] == repeat) where = member;
            }
            try check.fail(where, .{
                .code = .duplicate_member,
                .message = try comp.fmt("'{s}' is already a member of this union", .{
                    try comp.typeName(repeat),
                }),
                .label = "the same type again",
                .help = "members are distinct types, and an alias is not a new type",
            });
            return .poison;
        },
        .too_many => {
            try check.failTooWide(node);
            return .poison;
        },
    }
}

fn failTooWide(check: *Check, node: Node.Index) Allocator.Error!void {
    @branchHint(.cold);
    try check.fail(node, .{
        .code = .union_too_wide,
        .message = try check.comp.fmt("flat, a union holds at most {d} members", .{
            Pool.union_members_max,
        }),
        .label = "too wide",
    });
}

fn resolveTypeName(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));

    for (check.bindings) |binding| {
        if (std.mem.eql(u8, check.comp.pool.stringText(binding.name), text)) {
            return binding.type;
        }
    }
    if (Pool.preludeType(text)) |prelude| return prelude;

    const name = try check.comp.pool.string(check.comp.gpa, text);
    const decl_index = check.module.findDecl(name) orelse {
        try check.reportUndefined(node, text);
        return .poison;
    };
    return check.declAsType(decl_index, node);
}

fn declAsType(check: *Check, decl_index: Decl.Index, node: Node.Index) Allocator.Error!Pool.Index {
    const comp = check.comp;
    const decl = comp.declAt(decl_index);
    const name = comp.pool.stringText(decl.name);

    switch (decl.kind) {
        .struct_decl => {
            if (comp.typeParamCount(decl_index) > 0) {
                try check.fail(node, .{
                    .code = .generic_arguments,
                    .message = try comp.fmt("'{s}' is generic, so it needs its arguments", .{name}),
                    .label = "no arguments here",
                    .help = try comp.fmt("write '{s}[...]' with one type per parameter", .{name}),
                });
                return .poison;
            }
            const instance = try comp.instantiate(decl_index, &.{});
            return comp.instanceType(instance);
        },
        .type_alias => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            return @enumFromInt(comp.declAt(decl_index).result);
        },
        .unit_decl => {
            assert(comp.typeParamCount(decl_index) == 0);
            const instance = try comp.instantiate(decl_index, &.{});
            return comp.instanceType(instance);
        },
        .import => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            switch (Module.importTarget(comp, decl_index)) {
                .decl => |target| return check.declAsType(target, node),
                .module => {
                    try check.fail(node, .{
                        .code = .not_a_type,
                        .message = try comp.fmt("'{s}' is a module, not a type", .{name}),
                        .label = "a module",
                        .help = "name a type inside it",
                    });
                    return .poison;
                },
            }
        },
        .let, .fn_decl => {
            const what: []const u8 = if (decl.kind == .let) "a value" else "a function";
            try check.fail(node, .{
                .code = .not_a_type,
                .message = try comp.fmt("'{s}' is {s}, not a type", .{ name, what }),
                .label = "not a type",
            });
            return .poison;
        },
    }
}

/// Needs the base to name a generic struct.
fn resolveBracketType(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const comp = check.comp;
    const view = check.tree.viewOf(node).bracket;

    const base = try check.checkExpr(view.base, null);
    const decl_index = switch (base) {
        .named_generic => |decl_index| decl_index,
        .named_type, .named_fn => {
            try check.fail(node, .{
                .code = .generic_arguments,
                .message = if (base == .named_type)
                    "this type takes no type arguments"
                else
                    "a function is not a type",
                .label = "arguments on the wrong thing",
            });
            return .poison;
        },
        .poison => return .poison,
        else => {
            try check.fail(view.base, .{
                .code = .not_a_type,
                .message = "only a generic struct takes type arguments here",
                .label = "not a generic type",
            });
            return .poison;
        },
    };

    const wanted = comp.typeParamCount(decl_index);
    if (view.args.len != wanted) {
        const name = comp.pool.stringText(comp.declAt(decl_index).name);
        try check.fail(node, .{
            .code = .generic_arguments,
            .message = try comp.fmt("'{s}' takes {d} type argument{s}, and this writes {d}", .{
                name, wanted, plural(wanted), view.args.len,
            }),
            .label = "wrong number of arguments",
        });
        return .poison;
    }

    var args_buffer: [type_params_max]Pool.Index = undefined;
    assert(view.args.len <= args_buffer.len);
    for (view.args, 0..) |arg, position| {
        const resolved = try check.resolveType(arg);
        if (resolved == .poison) return .poison;
        args_buffer[position] = resolved;
    }

    const instance = try comp.instantiate(decl_index, args_buffer[0..view.args.len]);
    return comp.instanceType(instance);
}

/// Everything a body build carries. Blocks are contiguous runs.
const Builder = struct {
    instance: Pool.Instance,
    return_type: Pool.Index,
    insts: IR.Func.InstList,
    extra: std.ArrayList(u32),
    blocks: std.ArrayList(BlockBuild),
    current: IR.Block.Index,
    locals: std.ArrayList(Local),
    scopes: std.ArrayList(Scope),
    defer_nodes: std.ArrayList(Node.Index),
    loops: std.ArrayList(Loop),
    /// Staged call arguments and field values, marked and restored.
    operands: std.ArrayList(Operand),
    in_defer: bool,
    /// Unreachable code is still checked, then dropped.
    reachable: bool,

    const BlockBuild = struct { first: u32, count: u32, terminator: IR.Terminator };

    /// Where a field was given, `.none` otherwise.
    const Operand = struct { value: Value, initializer: Node.OptionalIndex };

    const Local = struct {
        name: Pool.String,
        node: Node.Index,
        kind: Kind,
        /// A ref, or a pool constant for `let_constant`.
        payload: u32,
        /// A `var_slot` ref is a pointer to this.
        type: Pool.Index,

        const Kind = enum(u8) { let_constant, let_value, var_slot, param };
    };

    const Scope = struct {
        locals_start: u32,
        defers_start: u32,
    };

    const Loop = struct {
        continue_target: IR.Block.Index,
        break_target: IR.Block.Index,
        /// A `break` unwinds to here.
        scope: u32,
        /// Whether a reachable `break` was seen.
        has_live_break: bool,
    };

    fn blockAt(builder: *Builder, index: IR.Block.Index) *BlockBuild {
        assert(index.int() < builder.blocks.items.len);
        return &builder.blocks.items[index.int()];
    }

    fn currentBlock(builder: *Builder) *BlockBuild {
        return builder.blockAt(builder.current);
    }

    const Mark = struct {
        insts: usize,
        extra: usize,
        blocks: usize,
        locals: usize,
        scopes: usize,
        loops: usize,
        operands: usize,
        current: IR.Block.Index,
    };

    fn mark(builder: *const Builder) Mark {
        return .{
            .insts = builder.insts.len,
            .extra = builder.extra.items.len,
            .blocks = builder.blocks.items.len,
            .locals = builder.locals.items.len,
            .scopes = builder.scopes.items.len,
            .loops = builder.loops.items.len,
            .operands = builder.operands.items.len,
            .current = builder.current,
        };
    }

    fn rewind(builder: *Builder, to: Mark) void {
        assert(builder.scopes.items.len == to.scopes);
        assert(builder.loops.items.len == to.loops);
        assert(builder.operands.items.len == to.operands);

        builder.insts.shrinkRetainingCapacity(to.insts);
        builder.extra.shrinkRetainingCapacity(to.extra);
        builder.blocks.shrinkRetainingCapacity(to.blocks);
        builder.locals.shrinkRetainingCapacity(to.locals);
        builder.current = to.current;

        const open = builder.currentBlock();
        open.terminator = .none;
        open.count = 0;
    }

    fn deinit(builder: *Builder, gpa: Allocator) void {
        builder.insts.deinit(gpa);
        builder.extra.deinit(gpa);
        builder.blocks.deinit(gpa);
        builder.locals.deinit(gpa);
        builder.scopes.deinit(gpa);
        builder.defer_nodes.deinit(gpa);
        builder.loops.deinit(gpa);
        builder.operands.deinit(gpa);
        builder.* = undefined;
    }
};

/// One body into a `Func`. The signature is already resolved.
pub fn fnBody(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    const decl = comp.declAt(decl_index);
    if (comp.instanceAt(instance).rows_state != .done) return false;

    var buffer: [bindings_max]Binding = undefined;
    const bindings = try bindTypeParams(comp, instance, &buffer);
    var check = context(comp, decl_index, bindings);

    var builder: Builder = .{
        .instance = instance,
        .return_type = comp.instanceType(instance),
        .insts = .empty,
        .extra = .empty,
        .blocks = .empty,
        .current = .entry,
        .locals = .empty,
        .scopes = .empty,
        .defer_nodes = .empty,
        .loops = .empty,
        .operands = .empty,
        .in_defer = false,
        .reachable = true,
    };
    defer builder.deinit(comp.gpa);
    check.builder = &builder;

    // one instruction per two source bytes of the body
    try builder.insts.ensureTotalCapacity(comp.gpa, 64);
    try builder.blocks.ensureTotalCapacity(comp.gpa, 8);

    const view = check.tree.viewOf(check.declNode(decl_index)).fn_decl;
    const entry = try check.newBlock();
    assert(entry == .entry);
    check.startBlock(entry);

    const rows = comp.instanceRows(instance);
    for (rows) |row| {
        const param_ref = try check.emit(.param, row.type, .{ .name = row.name });
        try check.declareLocal(.{
            .name = row.name,
            .node = row.node,
            .kind = .param,
            .payload = @intFromEnum(param_ref),
            .type = row.type,
        }, row.node);
    }

    // a body is statement position, so `return` is always written
    _ = try check.checkBlockValue(view.body, .void_type);
    if (check.blockOpen()) {
        const falls_off = builder.reachable and builder.return_type != .void_type;
        if (falls_off) {
            try check.failToken(view.name_token, .{
                .code = .missing_return,
                .message = try comp.fmt("not every path through '{s}' returns its {s}", .{
                    comp.pool.stringText(decl.name),
                    try comp.typeName(builder.return_type),
                }),
                .label = "a path falls off the end",
                .help = "every path must end in 'return', or loop forever",
            });
        }
        check.endBlock(.{ .ret = .none });
    }
    assert(builder.scopes.items.len == 0);

    try check.finishFunc();
    return true;
}

// blocks and instructions

fn emit(
    check: *Check,
    tag: IR.Inst.Tag,
    type_index: Pool.Index,
    data: IR.Inst.Data,
) Allocator.Error!Ref {
    const builder = check.builder.?;
    // control may have left inside a subexpression, so what follows lands in
    // a block nothing jumps to, which `finish` drops
    if (builder.currentBlock().terminator != .none) {
        const dead = try check.newBlock();
        check.startBlock(dead);
        builder.reachable = false;
    }

    if (builder.insts.len >= std.math.maxInt(u32) / 2) return error.OutOfMemory;
    const index: IR.Inst.Index = .from(builder.insts.len);
    try builder.insts.append(check.comp.gpa, .{
        .tag = tag,
        .type = type_index,
        .data = data,
    });
    return .fromInst(index);
}

fn emitOne(
    check: *Check,
    tag: IR.Inst.Tag,
    type_index: Pool.Index,
    operand: Ref,
) Allocator.Error!Ref {
    assert(operand != .none);
    return check.emit(tag, type_index, .{ .un = operand });
}

/// Producing the slot address. `.empty` names a checker temporary.
fn emitSlot(check: *Check, name: Pool.String, value_type: Pool.Index) Allocator.Error!Ref {
    const slot_type = try check.pointerTo(value_type, true);
    return check.emit(.local, slot_type, .{ .name = name });
}

fn emitStore(check: *Check, place: Ref, value: Ref) Allocator.Error!void {
    assert(place != .none);
    assert(value != .none);
    _ = try check.emit(.store, .void_type, .{ .bin = .{ .lhs = place, .rhs = value } });
}

fn newBlock(check: *Check) Allocator.Error!IR.Block.Index {
    const builder = check.builder.?;
    if (builder.blocks.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const index: IR.Block.Index = .from(builder.blocks.items.len);
    try builder.blocks.append(check.comp.gpa, .{
        .first = 0,
        .count = 0,
        .terminator = .none,
    });
    return index;
}

fn startBlock(check: *Check, block: IR.Block.Index) void {
    const builder = check.builder.?;
    const opened = builder.blockAt(block);
    assert(opened.terminator == .none);

    opened.first = @intCast(builder.insts.len);
    builder.current = block;
}

fn endBlock(check: *Check, terminator: IR.Terminator) void {
    const builder = check.builder.?;
    const block = builder.currentBlock();
    assert(terminator != .none);
    assert(block.terminator == .none);

    block.count = @as(u32, @intCast(builder.insts.len)) - block.first;
    block.terminator = terminator;
}

fn blockOpen(check: *const Check) bool {
    const builder = check.builder.?;
    return builder.currentBlock().terminator == .none;
}

// scopes, locals, and every way out

fn pushScope(check: *Check) Allocator.Error!void {
    const builder = check.builder.?;
    try builder.scopes.append(check.comp.gpa, .{
        .locals_start = @intCast(builder.locals.items.len),
        .defers_start = @intCast(builder.defer_nodes.items.len),
    });
}

fn popScope(check: *Check) void {
    const builder = check.builder.?;
    const scope = builder.scopes.pop().?;
    builder.locals.shrinkRetainingCapacity(scope.locals_start);
    builder.defer_nodes.shrinkRetainingCapacity(scope.defers_start);
}

/// Every scope from the innermost down to `target`, defers in reverse.
/// Every way out goes through here.
fn unwindScopesTo(check: *Check, target: u32) Allocator.Error!void {
    const builder = check.builder.?;
    assert(target <= builder.scopes.items.len);

    var index = builder.scopes.items.len;
    while (index > target) {
        index -= 1;
        const scope = builder.scopes.items[index];

        const defers_end = if (index + 1 < builder.scopes.items.len)
            builder.scopes.items[index + 1].defers_start
        else
            builder.defer_nodes.items.len;

        var defer_index = defers_end;
        while (defer_index > scope.defers_start) {
            defer_index -= 1;
            try check.emitDefer(builder.defer_nodes.items[defer_index]);
        }
    }
}

fn emitDefer(check: *Check, node: Node.Index) Allocator.Error!void {
    const builder = check.builder.?;
    const outer = builder.in_defer;

    builder.in_defer = true;
    defer builder.in_defer = outer;
    try check.checkStatement(node);
}

fn declareLocal(check: *Check, local: Builder.Local, node: Node.Index) Allocator.Error!void {
    const builder = check.builder.?;
    const text = check.comp.pool.stringText(local.name);

    // locals may not shadow anything visible
    const clash: ?Compilation.Report = clash: {
        for (builder.locals.items) |other| {
            if (other.name == local.name) {
                break :clash .{
                    .code = .shadows,
                    .message = try check.comp.fmt("'{s}' is already in scope", .{text}),
                    .label = "shadows the outer one",
                    .notes = try check.comp.notes(&.{
                        check.comp.noteAt(check.module_index, other.node, "first bound here"),
                    }),
                };
            }
        }
        for (check.bindings) |binding| {
            if (binding.name == local.name) {
                break :clash .{
                    .code = .shadows,
                    .message = try check.comp.fmt("'{s}' is a type parameter here", .{text}),
                    .label = "shadows it",
                };
            }
        }
        if (Pool.preludeType(text) != null) {
            break :clash .{
                .code = .shadows,
                .message = try check.comp.fmt("'{s}' is the name of a type every file can see", .{
                    text,
                }),
                .label = "shadows it",
            };
        }
        if (check.module.findDecl(local.name)) |decl_index| {
            const decl = check.comp.declAt(decl_index);
            break :clash .{
                .code = .shadows,
                .message = try check.comp.fmt("'{s}' is already declared in this file", .{text}),
                .label = "shadows it",
                .notes = try check.comp.notes(&.{
                    check.comp.noteAt(check.module_index, decl.node, "declared here"),
                }),
            };
        }
        break :clash null;
    };
    if (clash) |report| try check.fail(node, report);

    try builder.locals.append(check.comp.gpa, local);
}

fn findLocal(check: *const Check, name: []const u8) ?Builder.Local {
    const builder = check.builder orelse return null;
    var index = builder.locals.items.len;
    while (index > 0) {
        index -= 1;
        const local = builder.locals.items[index];
        if (std.mem.eql(u8, check.comp.pool.stringText(local.name), name)) return local;
    }
    return null;
}

// statements

/// One block with its own scope, worth its final expression.
fn checkBlockValue(check: *Check, node: Node.Index, hint: ?Pool.Index) Allocator.Error!Value {
    assert(check.tree.nodeTag(node) == .block);
    const builder = check.builder.?;
    const statements = check.tree.viewOf(node).block;

    try check.pushScope();
    const depth: u32 = @intCast(builder.scopes.items.len - 1);
    defer check.popScope();

    var value: Value = .void_value;
    for (statements, 0..) |statement, position| {
        if (check.blockOpen() == false or builder.reachable == false) {
            // entered dead, so whatever led here already reported
            if (position > 0) {
                try check.reportUnreachable(statement, statements[position - 1]);
            }
            break;
        }
        const tail = position + 1 == statements.len;
        const is_value = tail and wantsValue(hint) and
            tagIsStatement(check.tree.nodeTag(statement)) == false;
        if (is_value) {
            value = try check.checkExpr(statement, hint);
        } else {
            try check.checkStatement(statement);
        }
    }

    if (check.blockOpen() == false) return .diverged;
    try check.unwindScopesTo(depth);
    return value;
}

fn reportUnreachable(
    check: *Check,
    statement: Node.Index,
    left_at: Node.Index,
) Allocator.Error!void {
    try check.fail(statement, .{
        .code = .unreachable_code,
        .message = "this cannot be reached",
        .label = "never runs",
        .notes = try check.comp.notes(&.{
            check.comp.noteAt(check.module_index, left_at, "the block already left here"),
        }),
    });
}

fn checkStatement(check: *Check, node: Node.Index) Allocator.Error!void {
    assert(check.builder != null);

    switch (check.tree.viewOf(node)) {
        .var_decl => try check.checkVarDecl(node),
        .assign => |assign| try check.checkAssign(assign),
        .defer_stmt => |body| try check.checkDefer(body),
        .err => {},
        // a void hint tells an `if` to drop its value
        else => {
            const value = try check.checkExpr(node, .void_type);
            try check.expectNothing(node, value);
        },
    }
}

fn checkVarDecl(check: *Check, node: Node.Index) Allocator.Error!void {
    const comp = check.comp;
    const view = check.tree.viewOf(node).var_decl;
    const name_text = check.tree.tokenSlice(view.name_token);

    if (std.mem.eql(u8, name_text, "_")) {
        try check.fail(node, .{
            .code = .discard_reserved,
            .message = "'_' cannot be bound, because it is how a value is discarded",
            .label = "not a name",
            .help = "write '_ = expression' to drop the value on purpose",
        });
        return;
    }
    const name = try comp.pool.string(comp.gpa, name_text);

    const annotation: ?Pool.Index = if (view.type_expr.unwrap()) |type_expr|
        try check.resolveWrittenType(type_expr)
    else
        null;

    const value = try check.checkExpr(view.init_expr, annotation);

    switch (value) {
        .diverged => try check.declarePoisoned(name, node),
        .poison => {
            // a broken binding poisons its uses silently
            try check.declareLocal(.{
                .name = name,
                .node = node,
                .kind = .let_constant,
                .payload = Pool.Index.poison.int(),
                .type = .poison,
            }, node);
            return;
        },
        .constant => |constant| {
            const met = if (annotation) |wanted|
                try check.fitValue(constant, wanted, view.init_expr)
            else
                Value{ .constant = constant };
            switch (met) {
                .constant => |final| {
                    if (view.is_mutable) {
                        try check.checkVarDeclSlot(node, name, .{ .constant = final }, annotation);
                    } else {
                        try check.declareLocal(.{
                            .name = name,
                            .node = node,
                            .kind = .let_constant,
                            .payload = final.int(),
                            .type = comp.pool.typeOfValue(final),
                        }, node);
                    }
                },
                else => try check.checkVarDeclSlot(node, name, met, annotation),
            }
        },
        .runtime => try check.checkVarDeclSlot(node, name, value, annotation),
        else => {
            try check.reportNotValue(view.init_expr, value);
            try check.declarePoisoned(name, node);
        },
    }
}

/// Bind a runtime value. A `let` keeps the ref, a `var` gets storage.
fn checkVarDeclSlot(
    check: *Check,
    node: Node.Index,
    name: Pool.String,
    value: Value,
    annotation: ?Pool.Index,
) Allocator.Error!void {
    const comp = check.comp;
    const view = check.tree.viewOf(node).var_decl;

    var final = value;
    if (annotation) |wanted| final = try check.coerce(value, wanted, view.init_expr);

    const value_type = check.typeOf(final);
    if (value_type == .void_type) {
        try check.fail(view.init_expr, .{
            .code = .type_mismatch,
            .message = "this produces nothing, so there is nothing to bind",
            .label = "no value here",
        });
        return check.declarePoisoned(name, node);
    }
    if (value_type == .poison) return check.declarePoisoned(name, node);

    if (final == .constant and annotation == null) {
        assert(view.is_mutable);
        const spelled = switch (comp.pool.keyOf(final.constant)) {
            .value_int, .value_float => true,
            else => false,
        };
        if (spelled) {
            try check.fail(node, .{
                .code = .var_needs_type,
                .message = try comp.fmt("'{s}' needs a type before it can vary", .{
                    comp.pool.stringText(name),
                }),
                .label = "no type to hold it",
                .help = try comp.fmt("write 'var {s}: i64 = ...', or whichever type is meant", .{
                    comp.pool.stringText(name),
                }),
            });
            return check.declarePoisoned(name, node);
        }
    }

    if (view.is_mutable == false) {
        try check.declareLocal(.{
            .name = name,
            .node = node,
            .kind = .let_value,
            .payload = @intFromEnum(refOf(final)),
            .type = value_type,
        }, node);
        return;
    }

    const slot = try check.emitSlot(name, value_type);
    try check.emitStore(slot, refOf(final));
    try check.declareLocal(.{
        .name = name,
        .node = node,
        .kind = .var_slot,
        .payload = @intFromEnum(slot),
        .type = value_type,
    }, node);
}

fn declarePoisoned(check: *Check, name: Pool.String, node: Node.Index) Allocator.Error!void {
    try check.declareLocal(.{
        .name = name,
        .node = node,
        .kind = .let_constant,
        .payload = Pool.Index.poison.int(),
        .type = .poison,
    }, node);
}

fn checkAssign(check: *Check, assign: AST.View.Assign) Allocator.Error!void {
    if (assign.op == null and check.tree.nodeTag(assign.lhs) == .ident) {
        const text = check.tree.tokenSlice(check.tree.nodeMainToken(assign.lhs));
        if (std.mem.eql(u8, text, "_")) return check.checkDiscard(assign.rhs);
    }

    const place = try check.checkPlace(assign.lhs) orelse {
        _ = try check.checkExpr(assign.rhs, null);
        return;
    };
    if (place.mutable == false) {
        try check.reportImmutable(assign.lhs, place);
        _ = try check.checkExpr(assign.rhs, place.type);
        return;
    }
    assert(place.kind == .address);
    if (place.type == .poison) return;

    const value: Value = if (assign.op) |op| folded: {
        // the place is read once, worked on, and written back
        const held = try check.placeValue(place);
        const rhs = try check.checkExpr(assign.rhs, place.type);
        if (rhs == .diverged) return;
        if (try check.valueOnly(assign.rhs, rhs) == false) return;

        break :folded try check.combine(.{
            .op = op,
            .op_token = assign.op_token,
            .lhs = runtimeValue(held, place.type),
            .lhs_node = assign.lhs,
            .rhs = rhs,
            .rhs_node = assign.rhs,
        });
    } else try check.checkExpr(assign.rhs, place.type);

    const met = try check.coerce(value, place.type, assign.rhs);
    if (met == .poison) return;
    try check.emitStore(place.ref, refOf(met));
}

/// `_ = e` drops a value on purpose.
fn checkDiscard(check: *Check, rhs: Node.Index) Allocator.Error!void {
    const value = try check.checkExpr(rhs, null);
    switch (value) {
        .constant, .runtime, .poison, .diverged => {},
        else => return check.reportNotValue(rhs, value),
    }
    const found = check.typeOf(value);
    if (found == .poison) return;
}

fn checkIf(
    check: *Check,
    node: Node.Index,
    view: AST.View.If,
    hint: ?Pool.Index,
) Allocator.Error!Value {
    const builder = check.builder.?;
    const entry_reachable = builder.reachable;

    const wants = wantsValue(hint);
    if (wants and view.else_node == .none) {
        try check.fail(node, .{
            .code = .type_mismatch,
            .message = "this 'if' has no 'else', so one path through it produces nothing",
            .label = "needs an 'else'",
            .help = "an 'if' used as a value says what it is on every path",
        });
    }
    const carries = wants and view.else_node != .none;
    // named at the join when the context did not name a type
    const slot: Ref = if (carries)
        try check.emitSlot(.empty, hint orelse .poison)
    else
        .none;

    const then_block = try check.newBlock();
    const else_block = try check.newBlock();
    const join = try check.newBlock();

    const cond = try check.checkCondition(view.cond);
    check.endBlock(.{ .branch = .{
        .cond = cond,
        .then_block = then_block,
        .else_block = else_block,
    } });

    check.startBlock(then_block);
    const then_value = try check.checkExpr(view.then_block, hint);

    var result_type = hint orelse check.typeOf(then_value);
    if (carries and then_value != .diverged) {
        result_type = try check.settleArmType(node, result_type);
        try check.storeArm(slot, then_value, result_type, view.then_block);
    }

    var join_reachable = check.blockOpen() and builder.reachable;
    if (check.blockOpen()) check.endBlock(.{ .jump = join });

    check.startBlock(else_block);
    builder.reachable = entry_reachable;
    var else_value: Value = .diverged;
    if (view.else_node.unwrap()) |else_node| {
        else_value = try check.checkExpr(else_node, hint);
        if (carries and else_value != .diverged) {
            if (then_value == .diverged and hint == null) {
                result_type = try check.settleArmType(node, check.typeOf(else_value));
            }
            try check.storeArm(slot, else_value, result_type, else_node);
        }
        if (check.blockOpen() and builder.reachable) join_reachable = true;
        if (check.blockOpen()) check.endBlock(.{ .jump = join });
    } else {
        if (entry_reachable) join_reachable = true;
        check.endBlock(.{ .jump = join });
    }

    check.startBlock(join);
    builder.reachable = join_reachable;

    if (carries == false) return .void_value;

    // a later stage reads every type, so the slot is typed on every path
    try check.setSlotType(slot, if (result_type == .poison) .bool_type else result_type);

    if (then_value == .diverged and else_value == .diverged) return .diverged;
    if (result_type == .poison) return .poison;

    const loaded = try check.emitOne(.load, result_type, slot);
    return runtimeValue(loaded, result_type);
}

/// The type an arm settled on, or poison once reported.
fn settleArmType(check: *Check, node: Node.Index, found: Pool.Index) Allocator.Error!Pool.Index {
    if (found == .poison) return .poison;
    if (check.typeCanHold(found)) return found;

    if (found == .void_type) {
        try check.fail(node, .{
            .code = .type_mismatch,
            .message = "this 'if' produces nothing, so it cannot stand where a value does",
            .label = "no value here",
            .help = "an arm has to end in a value for the 'if' to have one",
        });
        return .poison;
    }
    // the same situation as `var x = 5`
    try check.fail(node, .{
        .code = .var_needs_type,
        .message = "the arms of this 'if' do not say what type it is",
        .label = "no type in sight",
        .help = "annotate what it feeds, as in 'let n: i64 = if ...'",
    });
    return .poison;
}

fn storeArm(
    check: *Check,
    slot: Ref,
    value: Value,
    wanted: Pool.Index,
    at: Node.Index,
) Allocator.Error!void {
    assert(value != .diverged);
    const met = try check.coerce(value, wanted, at);
    try check.emitStore(slot, refOf(met));
}

/// The one place a built instruction is rewritten. An `if` needs its slot
/// before its arms have said what type it is.
fn setSlotType(check: *Check, slot: Ref, value_type: Pool.Index) Allocator.Error!void {
    const builder = check.builder.?;
    const index = switch (slot.unwrap()) {
        .inst => |inst| inst.int(),
        .constant => unreachable,
    };
    assert(builder.insts.items(.tag)[index] == .local);
    builder.insts.items(.type)[index] = try check.pointerTo(value_type, true);
}

fn checkCondition(check: *Check, node: Node.Index) Allocator.Error!Ref {
    const value = try check.checkExpr(node, null);
    const found = check.typeOf(value);
    if (found == .bool_type) return refOf(value);
    if (found == .poison) return .fromConstant(.poison);

    try check.fail(node, .{
        .code = .condition_not_bool,
        .message = try check.comp.fmt("this condition is {s}, not a bool", .{
            try check.comp.typeName(found),
        }),
        .label = "not a bool",
    });
    return .fromConstant(.poison);
}

fn checkReturn(
    check: *Check,
    node: Node.Index,
    operand: Node.OptionalIndex,
) Allocator.Error!Value {
    const builder = check.builder.?;
    if (builder.in_defer) {
        try check.fail(node, .{
            .code = .defer_cannot_leave,
            .message = "a 'defer' runs on the way out, so it cannot leave again",
            .label = "no 'return' here",
        });
        return .poison;
    }

    if (operand.unwrap()) |value_node| {
        if (builder.return_type == .void_type) {
            try check.fail(node, .{
                .code = .type_mismatch,
                .message = "this function returns nothing, and this 'return' carries a value",
                .label = "nothing expected",
                .help = "drop the value, or give the function a return type",
            });
            _ = try check.checkExpr(value_node, null);
            check.endBlock(.{ .ret = .none });
            return .diverged;
        }
        const value = try check.checkExpr(value_node, builder.return_type);
        const met = try check.coerce(value, builder.return_type, value_node);
        // the operand may have left, and a block cannot be left twice
        if (check.blockOpen() == false) return .diverged;
        try check.unwindScopesTo(0);
        check.endBlock(.{ .ret = refOf(met) });
        return .diverged;
    }

    if (builder.return_type != .void_type) {
        try check.fail(node, .{
            .code = .type_mismatch,
            .message = try check.comp.fmt("'return' here must carry a {s}", .{
                try check.comp.typeName(builder.return_type),
            }),
            .label = "returns nothing",
        });
    }
    try check.unwindScopesTo(0);
    check.endBlock(.{ .ret = .none });
    return .diverged;
}

const LoopJump = enum { breaking, continuing };

fn checkLoopJump(check: *Check, node: Node.Index, jump: LoopJump) Allocator.Error!Value {
    const builder = check.builder.?;
    if (builder.in_defer) {
        try check.fail(node, .{
            .code = .defer_cannot_leave,
            .message = "a 'defer' runs on the way out, so it cannot leave again",
            .label = "not allowed here",
        });
        return .poison;
    }
    if (builder.loops.items.len == 0) {
        try check.fail(node, .{
            .code = .outside_loop,
            .message = "there is no loop here to leave",
            .label = "outside every loop",
        });
        return .poison;
    }

    const loop = &builder.loops.items[builder.loops.items.len - 1];
    try check.unwindScopesTo(loop.scope);
    switch (jump) {
        .breaking => {
            if (builder.reachable) loop.has_live_break = true;
            check.endBlock(.{ .jump = loop.break_target });
        },
        .continuing => check.endBlock(.{ .jump = loop.continue_target }),
    }
    return .diverged;
}

fn checkDefer(check: *Check, body: Node.Index) Allocator.Error!void {
    try check.builder.?.defer_nodes.append(check.comp.gpa, body);
}

/// A statement expression must amount to nothing.
fn expectNothing(check: *Check, node: Node.Index, value: Value) Allocator.Error!void {
    switch (value) {
        .poison, .diverged => return,
        .constant, .runtime => {},
        else => return check.reportNotValue(node, value),
    }

    const found = check.typeOf(value);
    if (found == .void_type) return;
    if (found == .poison) return;

    try check.reportUnusedValue(node, found, "bind it, return it, or drop it with '_ ='");
}

/// A constant that has not met a type has no name to print.
fn reportUnusedValue(
    check: *Check,
    node: Node.Index,
    found: Pool.Index,
    help: []const u8,
) Allocator.Error!void {
    const named = check.typeCanHold(found);
    try check.fail(node, .{
        .code = .value_unused,
        .message = if (named)
            try check.comp.fmt("this {s} goes nowhere", .{try check.comp.typeName(found)})
        else
            "this value goes nowhere",
        .label = "unused value",
        .help = help,
    });
}

// expressions

fn checkExpr(check: *Check, node: Node.Index, hint: ?Pool.Index) Allocator.Error!Value {
    // a top-level binding has no body to lower into
    if (check.builder == null) {
        if (runtimeOnly(check.tree.nodeTag(node))) |what| return check.needRuntime(node, what);
    }

    switch (check.tree.viewOf(node)) {
        .intrinsic => {
            if (check.module.space != .std) {
                try check.fail(node, .{
                    .code = .intrinsic_outside_std,
                    .message = "only the standard library reaches 'intrinsic'",
                    .label = "not available here",
                    .help = "std wraps each one in an ordinary declaration, so call that instead",
                });
                return .poison;
            }
            return .named_intrinsic;
        },
        .ident => return check.checkIdent(node),
        .number_literal => return check.checkNumber(node),
        .bool_literal => |view| {
            return .{ .constant = if (view.value) .true_value else .false_value };
        },
        // a block reaches here as an arm
        .block => return check.checkBlockValue(node, hint),
        .if_expr => |view| return check.checkIf(node, view, hint),
        .return_expr => |operand| return check.checkReturn(node, operand),
        .break_expr => return check.checkLoopJump(node, .breaking),
        .continue_expr => return check.checkLoopJump(node, .continuing),
        .binary => |view| return check.checkBinary(view),
        .unary => |view| return check.checkUnary(view),
        .field_access => |view| return check.checkFieldAccess(node, view),
        .deref => return check.checkDeref(node),
        .call => return check.checkCall(node),
        .bracket => |view| return check.checkBracketExpr(node, view),
        .struct_literal => return check.checkStructLiteral(node),
        .err => return .poison,
        // the parser keeps statements out of expression position
        else => unreachable,
    }
}

fn checkIdent(check: *Check, node: Node.Index) Allocator.Error!Value {
    const comp = check.comp;
    const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));

    if (std.mem.eql(u8, text, "_")) {
        try check.fail(node, .{
            .code = .discard_reserved,
            .message = "'_' has no value, and only discards one",
            .label = "not a value",
        });
        return .poison;
    }

    if (check.findLocal(text)) |local| {
        switch (local.kind) {
            .let_constant => return .{ .constant = @enumFromInt(local.payload) },
            .let_value, .param => return runtimeValue(@enumFromInt(local.payload), local.type),
            .var_slot => {
                const slot: Ref = @enumFromInt(local.payload);
                const loaded = try check.emitOne(.load, local.type, slot);
                return runtimeValue(loaded, local.type);
            },
        }
    }

    for (check.bindings) |binding| {
        if (std.mem.eql(u8, comp.pool.stringText(binding.name), text)) {
            return .{ .named_type = binding.type };
        }
    }

    if (Pool.preludeType(text)) |prelude| return .{ .named_type = prelude };

    const name = try comp.pool.string(comp.gpa, text);
    if (check.module.findDecl(name)) |decl_index| {
        return check.declAsValue(decl_index, node);
    }

    try check.reportUndefined(node, text);
    return .poison;
}

fn declAsValue(check: *Check, decl_index: Decl.Index, node: Node.Index) Allocator.Error!Value {
    const comp = check.comp;
    const decl = comp.declAt(decl_index);
    switch (decl.kind) {
        .let => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            return .{ .constant = @enumFromInt(comp.declAt(decl_index).result) };
        },
        .fn_decl => return .{ .named_fn = decl_index },
        .struct_decl => {
            if (comp.typeParamCount(decl_index) > 0) return .{ .named_generic = decl_index };
            const instance = try comp.instantiate(decl_index, &.{});
            return .{ .named_type = comp.instanceType(instance) };
        },
        .type_alias => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            return .{ .named_type = @enumFromInt(comp.declAt(decl_index).result) };
        },
        // a unit type in a value position is its one value
        .unit_decl => {
            const instance = try comp.instantiate(decl_index, &.{});
            const value = try comp.pool.intern(comp.gpa, .{
                .value_unit = comp.instanceType(instance),
            });
            return .{ .constant = value };
        },
        .import => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            switch (Module.importTarget(comp, decl_index)) {
                .module => |target| return .{ .named_module = target },
                .decl => |target| return check.declAsValue(target, node),
            }
        },
    }
}

fn checkNumber(check: *Check, node: Node.Index) Allocator.Error!Value {
    const comp = check.comp;
    const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));
    assert(text.len > 0);

    const has_prefix = text.len > 1 and text[0] == '0' and switch (text[1]) {
        'x', 'X', 'o', 'O', 'b', 'B' => true,
        else => false,
    };
    const looks_float = has_prefix == false and
        (std.mem.indexOfAny(u8, text, ".eE") != null);

    if (looks_float) {
        const value = std.fmt.parseFloat(f64, text) catch {
            try check.reportBadNumber(node, text);
            return .poison;
        };
        if (std.math.isFinite(value) == false) {
            try check.fail(node, .{
                .code = .bad_number,
                .message = "this number is too large for a float",
                .label = "does not fit",
            });
            return .poison;
        }
        return .{ .constant = try comp.pool.intern(comp.gpa, .{
            .value_float = .{ .type = .untyped_float_type, .value = value },
        }) };
    }

    const value = std.fmt.parseInt(i128, text, 0) catch |err| switch (err) {
        error.Overflow => {
            try check.fail(node, .{
                .code = .bad_number,
                .message = "this number needs more than 128 bits, the width constants fold in",
                .label = "too large",
            });
            return .poison;
        },
        error.InvalidCharacter => {
            try check.reportBadNumber(node, text);
            return .poison;
        },
    };
    return .{ .constant = try comp.pool.intern(comp.gpa, .{
        .value_int = .{ .type = .untyped_int_type, .value = value },
    }) };
}

fn reportBadNumber(check: *Check, node: Node.Index, text: []const u8) Allocator.Error!void {
    try check.fail(node, .{
        .code = .not_a_number,
        .message = try check.comp.fmt("'{s}' is not a number the language knows", .{text}),
        .label = "unreadable",
        .help = "numbers are decimal, hex '0x', octal '0o', or binary '0b', " ++
            "with '.' and 'e' for floats",
    });
}

/// Two checked operands and the operator between them.
const Operation = struct {
    op: AST.BinaryOp,
    op_token: Token.Index,
    lhs: Value,
    lhs_node: Node.Index,
    rhs: Value,
    rhs_node: Node.Index,
};

fn checkBinary(check: *Check, view: AST.View.Binary) Allocator.Error!Value {
    if (view.op == .bool_and or view.op == .bool_or) {
        return check.checkShortCircuit(view);
    }

    const lhs = try check.checkExpr(view.lhs, null);
    const rhs = try check.checkExpr(view.rhs, null);
    if (lhs == .diverged or rhs == .diverged) return .diverged;
    if (lhs == .poison or rhs == .poison) return .poison;
    if (try check.valueOnly(view.lhs, lhs) == false) return .poison;
    if (try check.valueOnly(view.rhs, rhs) == false) return .poison;

    return check.combine(.{
        .op = view.op,
        .op_token = view.op_token,
        .lhs = lhs,
        .lhs_node = view.lhs,
        .rhs = rhs,
        .rhs_node = view.rhs,
    });
}

/// Folded when both sides are constants, emitted otherwise.
fn combine(check: *Check, it: Operation) Allocator.Error!Value {
    const comp = check.comp;
    assert(it.op != .bool_and);
    assert(it.op != .bool_or);

    if (it.lhs == .constant and it.rhs == .constant) {
        const folded = try comp.pool.fold(comp.gpa, it.op, it.lhs.constant, it.rhs.constant);
        return check.settleFold(it.op_token, folded);
    }
    return check.emitBinary(it);
}

/// Every edge of a fold reports at the operator.
fn settleFold(check: *Check, op_token: Token.Index, folded: Pool.Fold) Allocator.Error!Value {
    const comp = check.comp;
    const spelling = check.tree.tokenSlice(op_token);
    const report: Compilation.Report = switch (folded) {
        .value => |value| return .{ .constant = value },
        .overflow => .{
            .code = .overflow,
            .message = "this overflows the 128 bits constants fold in",
            .label = "too large",
        },
        .division_by_zero => .{
            .code = .division_by_zero,
            .message = "this divides by zero",
            .label = "the divisor is zero",
        },
        .bad_shift => |amount| .{
            .code = .bad_shift,
            .message = try comp.fmt("a shift counts from 0 to {d}, and this shifts by {d}", .{
                Pool.fold_bits - 1,
                amount,
            }),
            .label = "not a shift count",
        },
        .does_not_fit => |missed| .{
            .code = .does_not_fit,
            .message = try comp.fmt("{d} does not fit in {s}", .{
                missed.value,
                try comp.typeName(missed.type),
            }),
            .label = "past the type's edge",
        },
        .mismatch => |pair| .{
            .code = .mixed_types,
            .message = try comp.fmt("'{s}' mixes {s} and {s}", .{
                spelling,
                try comp.typeName(pair.left),
                try comp.typeName(pair.right),
            }),
            .label = "two different types",
            .help = "nothing converts on its own, so give both sides one type",
        },
        .bad_operand => |operand_type| .{
            .code = .bad_operand,
            .message = try comp.fmt("'{s}' cannot be applied to {s}", .{
                spelling,
                try comp.typeName(operand_type),
            }),
            .label = "wrong operand type",
        },
    };
    try check.failToken(op_token, report);
    return .poison;
}

fn emitBinary(check: *Check, it: Operation) Allocator.Error!Value {
    const comp = check.comp;
    var lhs = it.lhs;
    var rhs = it.rhs;

    // a constant takes the runtime side's type
    if (lhs == .constant) lhs = try check.coerce(lhs, check.typeOf(rhs), it.lhs_node);
    if (rhs == .constant) rhs = try check.coerce(rhs, check.typeOf(lhs), it.rhs_node);
    if (lhs == .poison or rhs == .poison) return .poison;

    const left = check.typeOf(lhs);
    const right = check.typeOf(rhs);
    if (left != right) {
        try check.failToken(it.op_token, .{
            .code = .mixed_types,
            .message = try comp.fmt("'{s}' mixes {s} and {s}", .{
                check.tree.tokenSlice(it.op_token),
                try comp.typeName(left),
                try comp.typeName(right),
            }),
            .label = "two different types",
            .help = "nothing converts on its own, so give both sides one type",
        });
        return .poison;
    }

    const admissible = switch (it.op) {
        .add, .sub, .mul, .div => Pool.isNumeric(left),
        .mod => Pool.isInteger(left),
        .bit_and, .bit_or, .bit_xor => Pool.isInteger(left),
        .shift_left, .shift_right => Pool.isInteger(left),
        .less_than, .less_or_equal, .greater_than, .greater_or_equal => Pool.isNumeric(left),
        .equal, .not_equal => Pool.isNumeric(left) or left == .bool_type,
        .bool_and, .bool_or => unreachable,
    };
    if (admissible == false) {
        try check.reportBadOperand(it.op_token, left);
        return .poison;
    }

    const tag: IR.Inst.Tag = switch (it.op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shift_left => .shift_left,
        .shift_right => .shift_right,
        .equal => .cmp_eq,
        .not_equal => .cmp_ne,
        .less_than => .cmp_lt,
        .less_or_equal => .cmp_le,
        .greater_than => .cmp_gt,
        .greater_or_equal => .cmp_ge,
        .bool_and, .bool_or => unreachable,
    };
    const result_type: Pool.Index = switch (it.op) {
        .add, .sub, .mul, .div, .mod => left,
        .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => left,
        else => .bool_type,
    };
    const result = try check.emit(tag, result_type, .{
        .bin = .{ .lhs = refOf(lhs), .rhs = refOf(rhs) },
    });
    return runtimeValue(result, result_type);
}

/// `and` and `or` are control flow, so the lowering is a branch and a slot.
fn checkShortCircuit(check: *Check, view: AST.View.Binary) Allocator.Error!Value {
    const lhs = try check.checkExpr(view.lhs, null);
    const lhs_met = try check.coerce(lhs, .bool_type, view.lhs);
    if (lhs_met == .poison) {
        _ = try check.checkExpr(view.rhs, null);
        return .poison;
    }

    if (lhs_met == .constant) {
        const decided = lhs_met.constant ==
            (if (view.op == .bool_and) Pool.Index.false_value else Pool.Index.true_value);
        if (decided) {
            // the left decides, and the right is still checked. only a body
            // has anything to take back
            if (check.builder) |builder| {
                const before = builder.mark();
                _ = try check.checkExpr(view.rhs, null);
                builder.rewind(before);
            } else {
                _ = try check.checkExpr(view.rhs, null);
            }
            return lhs_met;
        }
        const rhs = try check.checkExpr(view.rhs, null);
        return check.coerce(rhs, .bool_type, view.rhs);
    }

    const slot = try check.emitSlot(.empty, .bool_type);
    try check.emitStore(slot, refOf(lhs_met));

    const rhs_block = try check.newBlock();
    const join = try check.newBlock();
    check.endBlock(.{ .branch = switch (view.op) {
        .bool_and => .{ .cond = refOf(lhs_met), .then_block = rhs_block, .else_block = join },
        .bool_or => .{ .cond = refOf(lhs_met), .then_block = join, .else_block = rhs_block },
        else => unreachable,
    } });

    check.startBlock(rhs_block);
    const rhs = try check.checkExpr(view.rhs, null);
    const rhs_met = try check.coerce(rhs, .bool_type, view.rhs);
    try check.emitStore(slot, refOf(rhs_met));
    check.endBlock(.{ .jump = join });

    check.startBlock(join);
    const loaded = try check.emitOne(.load, .bool_type, slot);
    return runtimeValue(loaded, .bool_type);
}

fn checkUnary(check: *Check, view: AST.View.Unary) Allocator.Error!Value {
    const comp = check.comp;
    if (view.op == .address_of) return check.checkAddressOf(view);

    const operand = try check.checkExpr(view.operand, null);
    if (operand == .diverged) return .diverged;
    if (operand == .poison) return .poison;
    if (try check.valueOnly(view.operand, operand) == false) return .poison;

    if (operand == .constant) {
        const folded = switch (view.op) {
            .negate => try comp.pool.foldNegate(comp.gpa, operand.constant),
            .bool_not => comp.pool.foldNot(operand.constant),
            .bit_not => try comp.pool.foldBitNot(comp.gpa, operand.constant),
            .address_of => unreachable,
        };
        return check.settleFold(view.op_token, folded);
    }

    const found = check.typeOf(operand);
    switch (view.op) {
        .address_of => unreachable,
        .negate => {
            const signed = switch (found) {
                .i8_type, .i16_type, .i32_type, .i64_type => true,
                .f32_type, .f64_type => true,
                else => false,
            };
            if (signed == false) {
                return check.reportBadUnary(view, found, "needs a signed number");
            }
            const result = try check.emitOne(.negate, found, refOf(operand));
            return runtimeValue(result, found);
        },
        .bool_not => {
            const met = try check.coerce(operand, .bool_type, view.operand);
            if (met == .poison) return .poison;
            const result = try check.emitOne(.not, .bool_type, refOf(met));
            return runtimeValue(result, .bool_type);
        },
        .bit_not => {
            if (Pool.isInteger(found) == false) {
                return check.reportBadUnary(view, found, "needs an integer");
            }
            const result = try check.emitOne(.bit_not, found, refOf(operand));
            return runtimeValue(result, found);
        },
    }
}

fn reportBadUnary(
    check: *Check,
    view: AST.View.Unary,
    found: Pool.Index,
    wants: []const u8,
) Allocator.Error!Value {
    try check.failToken(view.op_token, .{
        .code = .bad_operand,
        .message = try check.comp.fmt("'{s}' {s}, and this is {s}", .{
            check.tree.tokenSlice(view.op_token),
            wants,
            try check.comp.typeName(found),
        }),
        .label = "wrong operand type",
    });
    return .poison;
}

/// `&x`, which spills to a temporary when `x` has no address of its own.
fn checkAddressOf(check: *Check, view: AST.View.Unary) Allocator.Error!Value {
    const comp = check.comp;
    const place = try check.checkPlace(view.operand) orelse return .poison;
    if (check.typeCanHold(place.type) == false) {
        try check.failToken(view.op_token, .{
            .code = .type_mismatch,
            .message = try comp.fmt("'&' needs a value with a type, and this is {s}", .{
                try comp.typeName(place.type),
            }),
            .label = "nothing to point at",
            .help = "give the value a type first, as in 'let n: i64 = 10'",
        });
        return .poison;
    }
    const addressed = try check.placeAddress(place) orelse return .poison;
    return runtimeValue(addressed.ref, try check.pointerTo(addressed.type, addressed.mutable));
}

fn checkFieldAccess(
    check: *Check,
    node: Node.Index,
    view: AST.View.FieldAccess,
) Allocator.Error!Value {
    const comp = check.comp;
    const base = try check.checkExpr(view.lhs, null);
    const name_text = check.tree.tokenSlice(view.name_token);

    switch (base) {
        .poison => return .poison,
        .diverged => return .diverged,
        .named_module => |target| {
            const member = try check.moduleMember(target, node, view.name_token) orelse
                return .poison;
            return check.declAsValue(member, node);
        },
        .named_type, .named_generic => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = try comp.fmt("'{s}' is reached through a value or called, " ++
                    "and cannot be read", .{name_text}),
                .label = "not a value",
            });
            return .poison;
        },
        .named_fn => {
            try check.fail(node, .{
                .code = .no_such_member,
                .message = "a function has no fields, so call it first",
                .label = "'.' on a function",
            });
            return .poison;
        },
        .named_intrinsic => {
            try check.failIntrinsicNotValue(node);
            return .poison;
        },
        .constant, .runtime => {
            const found = check.typeOf(base);
            return check.valueField(node, view, base, found);
        },
    }
}

/// Through a struct, or through one pointer.
fn valueField(
    check: *Check,
    node: Node.Index,
    view: AST.View.FieldAccess,
    base: Value,
    found: Pool.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    const name_text = check.tree.tokenSlice(view.name_token);

    switch (comp.pool.keyOf(found)) {
        .type_struct => |instance| {
            const row = try check.findField(instance, view.name_token) orelse return .poison;
            const row_type = comp.rowAt(row).type;
            const result = try check.emit(.field_val, row_type, .{
                .field = .{ .base = refOf(base), .row = row },
            });
            return runtimeValue(result, row_type);
        },
        .type_pointer => |pointer| {
            switch (comp.pool.keyOf(pointer.child)) {
                .type_struct => |instance| {
                    const row = try check.findField(instance, view.name_token) orelse
                        return .poison;
                    const row_type = comp.rowAt(row).type;
                    const field_pointer = try check.pointerTo(row_type, pointer.mutable);
                    const place = try check.emit(.field_ptr, field_pointer, .{
                        .field = .{ .base = refOf(base), .row = row },
                    });
                    const loaded = try check.emitOne(.load, row_type, place);
                    return runtimeValue(loaded, row_type);
                },
                else => {},
            }
            try check.reportNoField(node, found, name_text);
            return .poison;
        },
        else => {
            try check.reportNoField(node, found, name_text);
            return .poison;
        },
    }
}

fn reportNoField(
    check: *Check,
    node: Node.Index,
    found: Pool.Index,
    name: []const u8,
) Allocator.Error!void {
    try check.fail(node, .{
        .code = .no_such_member,
        .message = try check.comp.fmt("{s} has nothing named '{s}'", .{
            try check.comp.typeName(found),
            name,
        }),
        .label = "no such field",
    });
}

/// With a suggestion when the name misses.
fn findField(
    check: *Check,
    instance: Pool.Instance,
    name_token: Token.Index,
) Allocator.Error!?u32 {
    const comp = check.comp;
    const name_text = check.tree.tokenSlice(name_token);

    if (try check.fieldRow(instance, name_text)) |row| return row;

    const decl_index = comp.instanceDecl(instance);
    if (findMember(comp, decl_index, name_text) != null) {
        try check.failToken(name_token, .{
            .code = .no_such_member,
            .message = try comp.fmt("'{s}' is a function, so call it with '.{s}(...)'", .{
                name_text, name_text,
            }),
            .label = "a method, not a field",
        });
        return null;
    }

    try check.failToken(name_token, .{
        .code = .no_such_member,
        .message = try comp.fmt("'{s}' has no field named '{s}'", .{
            try comp.instanceName(instance), name_text,
        }),
        .label = "no such field",
        .help = try check.suggestField(instance, name_text),
    });
    return null;
}

/// Absolute, which is what the IR stores.
fn fieldRow(check: *Check, instance: Pool.Instance, name_text: []const u8) Allocator.Error!?u32 {
    const comp = check.comp;
    try comp.ensureRows(instance);

    const rows = comp.instanceAt(instance).rows;
    for (rows.start..rows.end()) |raw| {
        const row_name = comp.pool.stringText(comp.rowAt(@intCast(raw)).name);
        if (std.mem.eql(u8, row_name, name_text)) return @intCast(raw);
    }
    return null;
}

/// Whether this file may reach a member of another one.
fn memberIsVisible(check: *Check, member: Decl.Index, at: Token.Index) Allocator.Error!bool {
    const decl = check.comp.declAt(member);
    if (decl.module == check.module_index) return true;
    if (Module.declIsPub(check.comp, member)) return true;

    try check.failToken(at, .{
        .code = .private,
        .message = try check.comp.fmt("'{s}' is private to its file", .{
            check.comp.pool.stringText(decl.name),
        }),
        .label = "not public",
        .help = "mark it 'pub' to reach it from another file",
        .notes = try check.comp.notes(&.{
            check.comp.noteAt(decl.module, decl.node, "declared here"),
        }),
    });
    return false;
}

fn findMember(comp: *const Compilation, decl_index: Decl.Index, name_text: []const u8) ?Decl.Index {
    const decl = comp.declAt(decl_index);
    assert(decl.kind == .struct_decl);

    const members = decl.members();
    for (members.start..members.start + members.len) |raw| {
        const member = comp.declAt(.from(raw));
        if (member.kind != .fn_decl) continue;
        if (std.mem.eql(u8, comp.pool.stringText(member.name), name_text)) {
            return .from(raw);
        }
    }
    return null;
}

fn suggestField(
    check: *Check,
    instance: Pool.Instance,
    name_text: []const u8,
) Allocator.Error!?[]const u8 {
    const comp = check.comp;
    var best: ?[]const u8 = null;
    var best_distance: u32 = 3;

    for (comp.instanceRows(instance)) |row| {
        const candidate = comp.pool.stringText(row.name);
        considerName(candidate, name_text, &best, &best_distance);
    }
    const found = best orelse return null;
    return try comp.fmt("did you mean '{s}'?", .{found});
}

fn checkDeref(check: *Check, node: Node.Index) Allocator.Error!Value {
    const place = try check.checkPlace(node) orelse return .poison;
    const loaded = try check.placeValue(place);
    return runtimeValue(loaded, place.type);
}

/// Type arguments when the base is generic, an index otherwise.
fn checkBracketExpr(
    check: *Check,
    node: Node.Index,
    view: AST.View.Bracket,
) Allocator.Error!Value {
    const comp = check.comp;
    const base = try check.checkExpr(view.base, null);
    switch (base) {
        .named_generic => {
            const resolved = try check.resolveBracketType(node);
            if (resolved == .poison) return .poison;
            return .{ .named_type = resolved };
        },
        .named_fn => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = "a function with its type arguments is still not a value, so call it",
                .label = "missing the call",
            });
            return .poison;
        },
        .diverged => return .diverged,
        .poison => return .poison,
        .constant, .runtime => {
            try check.fail(node, .{
                .code = .not_indexable,
                .message = try comp.fmt("{s} cannot be indexed", .{
                    try comp.typeName(check.typeOf(base)),
                }),
                .label = "not something to index",
                .help = "no type holds more than one value yet, so nothing can be indexed",
            });
            return .poison;
        },
        else => {
            try check.fail(node, .{
                .code = .generic_arguments,
                .message = "only a generic struct or function takes type arguments",
                .label = "arguments on the wrong thing",
            });
            return .poison;
        },
    }
}

/// The literal names its type, so nothing infers it. Every field named, every
/// field present.
fn checkStructLiteral(check: *Check, node: Node.Index) Allocator.Error!Value {
    const comp = check.comp;
    const view = check.tree.viewOf(node).struct_literal;

    const wanted = try check.resolveType(view.type_expr);
    if (wanted == .poison) return .poison;

    const instance = switch (comp.pool.keyOf(wanted)) {
        .type_struct => |instance| instance,
        else => {
            try check.fail(view.type_expr, .{
                .code = .not_a_type,
                .message = try comp.fmt("{s} has no fields to give", .{
                    try comp.typeName(wanted),
                }),
                .label = "not a struct",
            });
            return .poison;
        },
    };

    try comp.ensureRows(instance);
    const rows = comp.instanceAt(instance).rows;

    // one slot per field, in declaration order
    const builder = check.builder.?;
    const start: u32 = @intCast(builder.operands.items.len);
    defer builder.operands.shrinkRetainingCapacity(start);
    try builder.operands.appendNTimes(comp.gpa, .{ .value = .poison, .initializer = .none }, rows.len);

    var clean = true;
    for (view.fields) |init_node| {
        if (check.tree.nodeTag(init_node) != .struct_field_init) continue;
        const field_init = check.tree.viewOf(init_node).struct_field_init;

        const row = try check.fieldRow(instance, check.tree.tokenSlice(field_init.name_token));
        const position: u32 = if (row) |absolute| absolute - rows.start else {
            _ = try check.findField(instance, field_init.name_token);
            _ = try check.checkExpr(field_init.value, null);
            clean = false;
            continue;
        };

        if (builder.operands.items[start + position].initializer.unwrap()) |first| {
            try check.failToken(field_init.name_token, .{
                .code = .redeclared,
                .message = try comp.fmt("'{s}' is given twice", .{
                    check.tree.tokenSlice(field_init.name_token),
                }),
                .label = "given again here",
                .notes = try comp.notes(&.{
                    comp.noteAt(check.module_index, first, "first given here"),
                }),
            });
            clean = false;
            continue;
        }
        builder.operands.items[start + position].initializer = init_node.toOptional();

        const row_type = comp.rowAt(rows.start + @as(u32, @intCast(position))).type;
        const value = try check.checkExpr(field_init.value, row_type);
        const met = try check.coerce(value, row_type, field_init.value);
        if (met == .poison) clean = false;
        builder.operands.items[start + position].value = met;
    }

    var missing: ?[]const u8 = null;
    for (0..rows.len) |position| {
        if (builder.operands.items[start + position].initializer != .none) continue;
        const name = comp.pool.stringText(comp.rowAt(rows.start + @as(u32, @intCast(position))).name);
        missing = if (missing) |earlier|
            try comp.fmt("{s}, '{s}'", .{ earlier, name })
        else
            try comp.fmt("'{s}'", .{name});
    }
    if (missing) |names| {
        try check.fail(node, .{
            .code = .missing_field,
            .message = try comp.fmt("this literal leaves out {s}", .{names}),
            .label = "incomplete",
            .help = "every field of the struct must be present, and there are no defaults",
        });
        return .poison;
    }
    if (clean == false) return .poison;

    const fields = builder.operands.items[start..];
    const payload = try check.emitExtra(&.{@intCast(fields.len)}, fields);
    const result = try check.emit(.struct_init, wanted, .{ .payload = payload });
    return runtimeValue(result, wanted);
}

/// A header, then one ref per operand, as `Func.callAt` reads it back.
fn emitExtra(
    check: *Check,
    header: []const u32,
    operands: []const Builder.Operand,
) Allocator.Error!IR.ExtraIndex {
    const builder = check.builder.?;
    if (builder.extra.items.len + header.len + operands.len > std.math.maxInt(u32)) {
        return error.OutOfMemory;
    }

    const start: u32 = @intCast(builder.extra.items.len);
    try builder.extra.ensureUnusedCapacity(check.comp.gpa, header.len + operands.len);
    builder.extra.appendSliceAssumeCapacity(header);
    for (operands) |operand| {
        const ref = refOf(operand.value);
        assert(ref != .none);
        builder.extra.appendAssumeCapacity(@intFromEnum(ref));
    }
    return @enumFromInt(start);
}

/// Every call goes through here. Reads the substituted signature, never a body.
fn checkCall(check: *Check, node: Node.Index) Allocator.Error!Value {
    const view = check.tree.viewOf(node).call;
    if (view.args.len > call_args_max) {
        try check.fail(node, .{
            .code = .wrong_arity,
            .message = try check.comp.fmt("a call takes at most {d} arguments", .{call_args_max}),
        });
        return .poison;
    }

    const callee = try check.resolveCallee(view.callee) orelse {
        for (view.args) |argument| _ = try check.checkExpr(argument, null);
        return .poison;
    };
    switch (callee.kind) {
        .intrinsic => |which| {
            return check.checkIntrinsic(node, which, callee.explicit orelse &.{}, view.args);
        },
        else => return check.checkCallResolved(node, callee, view.args),
    }
}

/// A method waits for its receiver type, so the receiver is walked once.
const Callee = struct {
    kind: Kind,
    /// The `[T, U]` written at the call site, resolved once the declaration
    /// is known.
    explicit: ?[]const Node.Index,

    const Kind = union(enum) {
        /// A plain function, or one reached through a module.
        direct: Decl.Index,
        /// `Type.f(...)`, whose arguments pass exactly as written.
        static: struct { decl: Decl.Index, owner: Pool.Instance },
        /// `value.f(...)`, where the value is the receiver.
        method: struct { receiver: Node.Index, name_token: Token.Index },
        /// An operation the compiler performs itself.
        intrinsic: Intrinsic,
    };
};

/// Without evaluating a receiver or an argument. Null once reported.
fn resolveCallee(check: *Check, callee_node: Node.Index) Allocator.Error!?Callee {
    switch (check.tree.viewOf(callee_node)) {
        .field_access => |access| return check.resolveCalleeMember(callee_node, access),
        .bracket => |bracket| {
            var callee = switch (check.tree.nodeTag(bracket.base)) {
                .field_access => try check.resolveCalleeMember(
                    bracket.base,
                    check.tree.viewOf(bracket.base).field_access,
                ) orelse return null,
                else => callee: {
                    const value = try check.checkExpr(bracket.base, null);
                    break :callee try check.calleeOfValue(bracket.base, value) orelse
                        return null;
                },
            };

            if (bracket.args.len > type_params_max) {
                try check.fail(callee_node, .{
                    .code = .generic_arguments,
                    .message = try check.comp.fmt(
                        "a call takes at most {d} type arguments",
                        .{type_params_max},
                    ),
                });
                return null;
            }
            callee.explicit = bracket.args;
            return callee;
        },
        else => {
            const value = try check.checkExpr(callee_node, null);
            return check.calleeOfValue(callee_node, value);
        },
    }
}

/// A module or type function when the chain is pure names, and a method
/// otherwise. The receiver is left unevaluated, because checking emits.
fn resolveCalleeMember(
    check: *Check,
    callee_node: Node.Index,
    access: AST.View.FieldAccess,
) Allocator.Error!?Callee {
    const comp = check.comp;
    const name_text = check.tree.tokenSlice(access.name_token);

    if (check.baseIsNamespace(access.lhs)) {
        const base = try check.checkExpr(access.lhs, null);
        switch (base) {
            .poison, .diverged => return null,
            .named_module => |target| {
                const member = try check.moduleMember(target, callee_node, access.name_token) orelse
                    return null;
                const value = try check.declAsValue(member, callee_node);
                return check.calleeOfValue(callee_node, value);
            },
            .named_type => |type_index| {
                switch (comp.pool.keyOf(type_index)) {
                    .type_struct => |owner| {
                        const decl_index = comp.instanceDecl(owner);
                        const member = findMember(comp, decl_index, name_text) orelse {
                            _ = try check.findField(owner, access.name_token);
                            return null;
                        };
                        if (try check.memberIsVisible(member, access.name_token) == false) {
                            return null;
                        }
                        return .{
                            .kind = .{ .static = .{ .decl = member, .owner = owner } },
                            .explicit = null,
                        };
                    },
                    else => {
                        try check.failToken(access.name_token, .{
                            .code = .no_such_member,
                            .message = try comp.fmt("{s} has no functions to call", .{
                                try comp.typeName(type_index),
                            }),
                            .label = "nothing here",
                        });
                        return null;
                    },
                }
            },
            .named_generic => {
                try check.fail(access.lhs, .{
                    .code = .generic_arguments,
                    .message = "this struct is generic, so write its arguments before reaching in",
                    .label = "missing type arguments",
                });
                return null;
            },
            .named_fn => {
                try check.failToken(access.name_token, .{
                    .code = .no_such_member,
                    .message = "a function has no fields, so call it first",
                    .label = "'.' on a function",
                });
                return null;
            },
            .named_intrinsic => {
                const which = Intrinsic.fromName(name_text) orelse {
                    try check.failToken(access.name_token, .{
                        .code = .no_such_member,
                        .message = try comp.fmt("there is no intrinsic named '{s}'", .{name_text}),
                        .label = "no such intrinsic",
                        .help = try check.suggestIntrinsic(name_text),
                    });
                    return null;
                };
                return .{ .kind = .{ .intrinsic = which }, .explicit = null };
            },
            // a pure name resolved to a constant is still a receiver
            .constant, .runtime => {},
        }
    }

    return .{
        .kind = .{ .method = .{ .receiver = access.lhs, .name_token = access.name_token } },
        .explicit = null,
    };
}

/// A chain of pure names rooted outside the locals, so checking cannot emit.
fn baseIsNamespace(check: *const Check, node: Node.Index) bool {
    var current = node;
    var depth: u32 = 0;
    while (depth < type_depth_max) : (depth += 1) {
        switch (check.tree.nodeTag(current)) {
            .ident => {
                const text = check.tree.tokenSlice(check.tree.nodeMainToken(current));
                if (check.findLocal(text) != null) return false;
                return true;
            },
            .intrinsic => return true,
            .field_access => current = check.tree.viewOf(current).field_access.lhs,
            .bracket => current = check.tree.viewOf(current).bracket.base,
            else => return false,
        }
    }
    return false;
}

fn calleeOfValue(check: *Check, node: Node.Index, value: Value) Allocator.Error!?Callee {
    const comp = check.comp;
    switch (value) {
        .named_fn => |decl_index| return .{
            .kind = .{ .direct = decl_index },
            .explicit = null,
        },
        .poison, .diverged => return null,
        .constant, .runtime => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = try comp.fmt("this is {s}, not a function", .{
                    try comp.typeName(check.typeOf(value)),
                }),
                .label = "cannot be called",
            });
            return null;
        },
        .named_type, .named_generic => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = "a type is not callable, and there are no conversions to call",
                .label = "a type",
            });
            return null;
        },
        .named_module => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = "a module is not callable, so name a function inside it",
                .label = "a module",
            });
            return null;
        },
        .named_intrinsic => {
            try check.failIntrinsicNotValue(node);
            return null;
        },
    }
}

/// Receiver, type arguments, signature, arguments, then the call or primitive.
fn checkCallResolved(
    check: *Check,
    node: Node.Index,
    callee: Callee,
    args: []const Node.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    const builder = check.builder.?;

    // the receiver is written first, so it is evaluated first
    var receiver_place: ?Place = null;
    var receiver_node: ?Node.Index = null;
    var owner_args: []const Pool.Index = &.{};
    const decl_index: Decl.Index = switch (callee.kind) {
        .intrinsic => unreachable,
        .direct => |direct| direct,
        .static => |static| static: {
            owner_args = comp.instanceArgs(static.owner);
            break :static static.decl;
        },
        .method => |method| method: {
            const place = try check.checkPlace(method.receiver) orelse return .poison;
            if (place.type == .poison) return .poison;
            receiver_place = place;
            receiver_node = method.receiver;

            const type_struct = peelOnePointer(comp, place.type);
            switch (comp.pool.keyOf(type_struct)) {
                .type_struct => |owner| {
                    const owner_decl = comp.instanceDecl(owner);
                    const name_text = check.tree.tokenSlice(method.name_token);
                    const member = findMember(comp, owner_decl, name_text) orelse {
                        _ = try check.findField(owner, method.name_token);
                        return .poison;
                    };
                    if (try check.memberIsVisible(member, method.name_token) == false) {
                        return .poison;
                    }
                    owner_args = comp.instanceArgs(owner);
                    break :method member;
                },
                else => {
                    try check.reportNotMethod(method.name_token, place.type);
                    return .poison;
                },
            }
        },
    };

    const decl = comp.declAt(decl_index);
    const fn_name = comp.pool.stringText(decl.name);
    const own_count = comp.typeParamCount(decl_index);

    // the owner's arguments move under instantiation
    var full_args: [bindings_max]Pool.Index = undefined;
    assert(owner_args.len <= type_params_max);
    assert(own_count <= type_params_max);
    assert(owner_args.len + own_count <= full_args.len);
    @memcpy(full_args[0..owner_args.len], owner_args);
    const owner_count: u32 = @intCast(owner_args.len);

    const mark: u32 = @intCast(builder.operands.items.len);
    defer builder.operands.shrinkRetainingCapacity(mark);

    var inferred = false;
    if (callee.explicit) |explicit| {
        if (explicit.len != own_count) {
            try check.fail(node, .{
                .code = .generic_arguments,
                .message = try comp.fmt("'{s}' takes {d} type argument{s}, and this writes {d}", .{
                    fn_name, own_count, plural(own_count), explicit.len,
                }),
                .label = "wrong number of arguments",
                .notes = try comp.notes(&.{
                    comp.noteAt(decl.module, decl.node, "declared here"),
                }),
            });
            return .poison;
        }
        for (explicit, 0..) |argument, position| {
            const resolved = try check.resolveWrittenType(argument);
            if (resolved == .poison) return .poison;
            full_args[owner_count + position] = resolved;
        }
    } else if (own_count > 0) {
        const solved = try check.inferTypeArguments(
            node,
            decl_index,
            receiver_place != null,
            args,
            full_args[owner_count..][0..own_count],
        );
        if (solved == false) return .poison;
        inferred = true;
    }
    const start: u32 = if (inferred) mark + @as(u32, @intCast(args.len)) else mark;

    const instance = try comp.instantiate(decl_index, full_args[0 .. owner_count + own_count]);
    try comp.ensure(.of(.signature, instance), check.origin(node));
    if (comp.instanceAt(instance).rows_state != .done) return .poison;
    const return_type = comp.instanceType(instance);

    // a receiver consumes the first parameter
    const rows = comp.instanceAt(instance).rows;
    var receiver_count: u32 = 0;
    if (receiver_place) |place| {
        if (rows.len == 0) {
            try check.fail(node, .{
                .code = .wrong_arity,
                .message = try comp.fmt("'{s}' takes no parameters, so it has no receiver", .{
                    fn_name,
                }),
                .label = "not a method",
                .help = "call it through the type instead",
                .notes = try comp.notes(&.{
                    comp.noteAt(decl.module, decl.node, "declared here"),
                }),
            });
            return .poison;
        }
        const self_type = comp.rowAt(rows.start).type;
        const receiver = try check.adaptReceiver(receiver_node.?, place, self_type, fn_name) orelse
            return .poison;
        try builder.operands.append(comp.gpa, .{
            .value = runtimeValue(receiver, self_type),
            .initializer = .none,
        });
        receiver_count = 1;
    }

    const expected = rows.len - receiver_count;
    if (args.len != expected) {
        try check.fail(node, .{
            .code = .wrong_arity,
            .message = try comp.fmt("'{s}' takes {d} argument{s}, and this call has {d}", .{
                fn_name, expected, plural(expected), args.len,
            }),
            .label = "wrong number of arguments",
            .notes = try comp.notes(&.{
                comp.noteAt(decl.module, decl.node, "declared here"),
            }),
        });
        if (inferred == false) {
            for (args) |argument| _ = try check.checkExpr(argument, null);
        }
        return .poison;
    }

    var clean = true;
    for (args, 0..) |argument, position| {
        const row_type = comp.rowAt(rows.start + receiver_count + @as(u32, @intCast(position))).type;
        const early: ?Value = if (inferred) builder.operands.items[mark + position].value else null;
        const met = try check.checkArgument(argument, row_type, early);
        if (met == .poison) clean = false;
        try builder.operands.append(comp.gpa, .{ .value = met, .initializer = .none });
    }
    if (clean == false) return .poison;
    assert(builder.operands.items.len == start + receiver_count + args.len);

    // on its own `Builder`, so the operands staged here cannot move
    try comp.ensure(.of(.body, instance), check.origin(node));

    const operands = builder.operands.items[start..];
    const payload = try check.emitExtra(&.{ instance.int(), @intCast(operands.len) }, operands);

    const result = try check.emit(.call, return_type, .{ .payload = payload });
    return runtimeValue(result, return_type);
}

/// Arity from the table, then the one case that knows what this intrinsic
/// means. A new intrinsic adds a row to `Intrinsic.shape` and an arm here.
fn checkIntrinsic(
    check: *Check,
    node: Node.Index,
    which: Intrinsic,
    type_args: []const Node.Index,
    args: []const Node.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    const shape = which.shape();
    const name = @tagName(which);

    if (type_args.len != shape.type_params) {
        try check.fail(node, .{
            .code = .generic_arguments,
            .message = try comp.fmt("'{s}' takes {d} type argument{s}, and this writes {d}", .{
                name, shape.type_params, plural(shape.type_params), type_args.len,
            }),
            .label = "wrong number of type arguments",
        });
        return .poison;
    }
    if (args.len != shape.params) {
        try check.fail(node, .{
            .code = .wrong_arity,
            .message = try comp.fmt("'{s}' takes {d} argument{s}, and this call has {d}", .{
                name, shape.params, plural(shape.params), args.len,
            }),
            .label = "wrong number of arguments",
        });
        return .poison;
    }

    var types: [intrinsic_limits.type_params_max]Pool.Index = undefined;
    for (type_args, 0..) |type_arg, position| {
        const resolved = try check.resolveWrittenType(type_arg);
        if (resolved == .poison) return .poison;
        types[position] = resolved;
    }

    var values: [intrinsic_limits.params_max]Value = undefined;
    for (args, 0..) |argument, position| {
        const value = try check.checkExpr(argument, null);
        if (value == .diverged) return .diverged;
        if (try check.valueOnly(argument, value) == false) return .poison;
        if (value == .poison) return .poison;
        values[position] = value;
    }

    switch (which) {
        .ptr_cast => return check.intrinsicPtrCast(args[0], types[0], values[0]),
    }
}

/// Retypes what a pointer points at, and keeps what the pointer may do, so a
/// read-only pointer cannot be laundered into one that writes.
fn intrinsicPtrCast(
    check: *Check,
    node: Node.Index,
    wanted: Pool.Index,
    operand: Value,
) Allocator.Error!Value {
    const comp = check.comp;
    const found = check.typeOf(operand);

    const pointer = switch (comp.pool.keyOf(found)) {
        .type_pointer => |it| it,
        else => {
            try check.fail(node, .{
                .code = .type_mismatch,
                .message = try comp.fmt("'ptr_cast' needs a pointer, and this is {s}", .{
                    try comp.typeName(found),
                }),
                .label = "not a pointer",
            });
            return .poison;
        },
    };

    const result = try check.pointerTo(wanted, pointer.mutable);
    const ref = try check.emitOne(.ptr_cast, result, refOf(operand));
    return runtimeValue(ref, result);
}

fn failIntrinsicNotValue(check: *Check, node: Node.Index) Allocator.Error!void {
    try check.fail(node, .{
        .code = .intrinsic_outside_std,
        .message = "an intrinsic is not a value, so call it",
        .label = "missing the call",
        .help = "write 'intrinsic.name(...)', with its type arguments if it takes any",
    });
}

fn suggestIntrinsic(check: *Check, text: []const u8) Allocator.Error!?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: u32 = 3;

    for (Intrinsic.names) |candidate| considerName(candidate, text, &best, &best_distance);
    const found = best orelse return null;
    return try check.comp.fmt("did you mean '{s}'?", .{found});
}

fn plural(count: u32) []const u8 {
    return if (count == 1) "" else "s";
}

fn peelOnePointer(comp: *const Compilation, type_index: Pool.Index) Pool.Index {
    return switch (comp.pool.keyOf(type_index)) {
        .type_pointer => |pointer| pointer.child,
        else => type_index,
    };
}

fn reportNotMethod(check: *Check, name_token: Token.Index, found: Pool.Index) Allocator.Error!void {
    const name_text = check.tree.tokenSlice(name_token);
    try check.failToken(name_token, .{
        .code = .no_such_member,
        .message = try check.comp.fmt("{s} has no method named '{s}'", .{
            try check.comp.typeName(found),
            name_text,
        }),
        .label = "no such method",
    });
}

/// Coerced to its parameter type. Never checked twice, because checking emits.
fn checkArgument(
    check: *Check,
    argument: Node.Index,
    row_type: Pool.Index,
    early: ?Value,
) Allocator.Error!Value {
    if (early) |value| return check.coerce(value, row_type, argument);

    const value = try check.checkExpr(argument, row_type);
    return check.coerce(value, row_type, argument);
}

/// Omitted bracket arguments, pinned by declared parameter types. A pin is
/// `value: T` directly or one pointer deep, all or nothing.
fn inferTypeArguments(
    check: *Check,
    node: Node.Index,
    decl_index: Decl.Index,
    has_receiver: bool,
    args: []const Node.Index,
    out: []Pool.Index,
) Allocator.Error!bool {
    const comp = check.comp;
    const builder = check.builder.?;
    const decl = comp.declAt(decl_index);
    const owner_tree = comp.treeOf(decl.module);
    const fn_view = owner_tree.viewOf(decl.node).fn_decl;
    const fn_name = comp.pool.stringText(decl.name);

    // in source order, so evaluation order survives
    const early: u32 = @intCast(builder.operands.items.len);
    for (args) |argument| {
        const value = try check.checkExpr(argument, null);
        try builder.operands.append(comp.gpa, .{ .value = value, .initializer = .none });
    }

    const receiver_rows: u32 = if (has_receiver) 1 else 0;
    for (fn_view.type_params, 0..) |type_param, param_position| {
        const wanted = owner_tree.tokenSlice(owner_tree.nodeMainToken(type_param));

        const pin = pinFor(owner_tree, fn_view, wanted, receiver_rows) orelse {
            try check.fail(node, .{
                .code = .inference_failed,
                .message = try comp.fmt(
                    "no value parameter of '{s}' pins '{s}', so it must be written",
                    .{ fn_name, wanted },
                ),
                .label = "cannot be inferred",
                .help = try comp.fmt("write the call '{s}[...](...)'", .{fn_name}),
            });
            return false;
        };
        if (pin.argument >= args.len) {
            try check.fail(node, .{
                .code = .inference_failed,
                .message = try comp.fmt("'{s}' would be pinned by an argument this call lacks", .{
                    wanted,
                }),
                .label = "too few arguments to infer from",
            });
            return false;
        }

        const pinned = builder.operands.items[early + pin.argument].value;
        var found = check.typeOf(pinned);
        if (found == .poison) return false;
        if (found == .untyped_int_type or found == .untyped_float_type) {
            try check.fail(args[pin.argument], .{
                .code = .inference_failed,
                .message = "a bare number has no type to read",
                .label = try comp.fmt("what type is '{s}'?", .{wanted}),
                .help = try comp.fmt(
                    "write the type argument, '{s}[i64](...)', or type the value first",
                    .{fn_name},
                ),
            });
            return false;
        }
        if (pin.through_pointer) {
            switch (comp.pool.keyOf(found)) {
                .type_pointer => |pointer| found = pointer.child,
                else => {
                    _ = try check.reportMismatch(args[pin.argument], pinned, .poison);
                    return false;
                },
            }
        }
        out[param_position] = found;
    }
    return true;
}

const Pin = struct { argument: u32, through_pointer: bool };

/// The first parameter declared as the named type parameter, or a pointer to
/// it. Read off the tree, before anything resolves.
fn pinFor(
    tree: *const AST,
    fn_view: AST.View.FnDecl,
    wanted: []const u8,
    receiver_rows: u32,
) ?Pin {
    for (fn_view.params, 0..) |param_node, position| {
        if (tree.nodeTag(param_node) != .param) continue;
        if (position < receiver_rows) continue;
        const param = tree.viewOf(param_node).param;

        var type_node = param.type_expr;
        var through_pointer = false;
        if (tree.nodeTag(type_node) == .pointer_type) {
            type_node = tree.viewOf(type_node).pointer_type.child;
            through_pointer = true;
        }
        if (tree.nodeTag(type_node) != .ident) continue;
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_node)), wanted)) {
            return .{
                .argument = @intCast(position - receiver_rows),
                .through_pointer = through_pointer,
            };
        }
    }
    return null;
}

/// As the first argument, in whichever form the declaration asked for.
fn adaptReceiver(
    check: *Check,
    receiver_node: Node.Index,
    place: Place,
    self_type: Pool.Index,
    fn_name: []const u8,
) Allocator.Error!?Ref {
    const comp = check.comp;
    assert(place.type != .poison);

    switch (comp.pool.keyOf(self_type)) {
        .type_pointer => |wanted| {
            // the receiver may already be the pointer, or need its address
            if (place.type == self_type) {
                return try check.placeValue(place);
            }
            const place_key = comp.pool.keyOf(place.type);
            if (place_key == .type_pointer and place_key.type_pointer.child == wanted.child) {
                if (wanted.mutable and place_key.type_pointer.mutable == false) {
                    try check.fail(receiver_node, .{
                        .code = .write_through_pointer,
                        .message = try comp.fmt(
                            "'{s}' writes through its receiver, and this is a '{s}'",
                            .{ fn_name, try comp.typeName(place.type) },
                        ),
                        .label = "read-only pointer",
                        .help = try comp.fmt("it needs '{s}'", .{try comp.typeName(self_type)}),
                    });
                    return null;
                }
                return try check.placeValue(place);
            }
            if (place.type == wanted.child) {
                if (wanted.mutable and place.mutable == false) {
                    try check.reportReceiverImmutable(receiver_node, place, fn_name);
                    return null;
                }
                const addressed = try check.placeAddress(place) orelse return null;
                return addressed.ref;
            }
            return check.reportReceiverMismatch(receiver_node, place.type, self_type, fn_name);
        },
        else => {
            // `self: T` takes a copy
            if (place.type == self_type) {
                return try check.placeValue(place);
            }
            const place_key = comp.pool.keyOf(place.type);
            if (place_key == .type_pointer and place_key.type_pointer.child == self_type) {
                // through one pointer, the way field access does
                const pointer = try check.placeValue(place);
                return try check.emitOne(.load, self_type, pointer);
            }
            return check.reportReceiverMismatch(receiver_node, place.type, self_type, fn_name);
        },
    }
}

fn reportReceiverImmutable(
    check: *Check,
    node: Node.Index,
    place: Place,
    fn_name: []const u8,
) Allocator.Error!void {
    const what: []const u8 = switch (place.reason) {
        .mutable => unreachable,
        .let_bound => "was bound with 'let'",
        .param_bound => "is a parameter, a copy that dies with the call",
        .const_pointer => "sits behind a read-only pointer",
        .temporary => "is a temporary that no one else can see",
    };
    try check.fail(node, .{
        .code = .not_assignable,
        .message = try check.comp.fmt("'{s}' writes through its receiver, and '{s}' {s}", .{
            fn_name, place.root_name, what,
        }),
        .label = "immutable receiver",
        .help = "bind it with 'var' to let a method change it",
    });
}

fn reportReceiverMismatch(
    check: *Check,
    node: Node.Index,
    found: Pool.Index,
    self_type: Pool.Index,
    fn_name: []const u8,
) Allocator.Error!?Ref {
    try check.fail(node, .{
        .code = .type_mismatch,
        .message = try check.comp.fmt("the first parameter of '{s}' is {s}, so {s} " ++
            "cannot be its receiver", .{
            fn_name,
            try check.comp.typeName(self_type),
            try check.comp.typeName(found),
        }),
        .label = "receiver and parameter disagree",
    });
    return null;
}

/// A location a chain of names reached. A `value` never had an address, and
/// is spilled to one only when something needs to point at it.
const Place = struct {
    kind: Kind,
    /// The address for `.address`, the value itself for `.value`.
    ref: Ref,
    /// The type at this point of the chain, the pointee for `.address`.
    type: Pool.Index,
    mutable: bool,
    reason: Reason,
    root_name: []const u8,
    root_node: Node.Index,

    const Kind = enum { address, value };
    const Reason = union(enum) {
        mutable,
        let_bound,
        param_bound,
        /// The read-only pointer type the chain crossed, for the message.
        const_pointer: Pool.Index,
        temporary,
    };
};

/// An expression as a location. Null once reported.
fn checkPlace(check: *Check, node: Node.Index) Allocator.Error!?Place {
    switch (check.tree.viewOf(node)) {
        .ident => {
            const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));
            if (std.mem.eql(u8, text, "_")) {
                try check.fail(node, .{
                    .code = .discard_reserved,
                    .message = "'_' is not a place, and only discards a whole value",
                    .label = "not a place",
                });
                return null;
            }
            if (check.findLocal(text)) |local| {
                if (local.type == .poison) return null;
                return switch (local.kind) {
                    .var_slot => .{
                        .kind = .address,
                        .ref = @enumFromInt(local.payload),
                        .type = local.type,
                        .mutable = true,
                        .reason = .mutable,
                        .root_name = text,
                        .root_node = local.node,
                    },
                    .let_constant => .{
                        .kind = .value,
                        .ref = .fromConstant(@enumFromInt(local.payload)),
                        .type = local.type,
                        .mutable = false,
                        .reason = .let_bound,
                        .root_name = text,
                        .root_node = local.node,
                    },
                    .let_value, .param => .{
                        .kind = .value,
                        .ref = @enumFromInt(local.payload),
                        .type = local.type,
                        .mutable = false,
                        .reason = switch (local.kind) {
                            .let_value => .let_bound,
                            .param => .param_bound,
                            else => unreachable,
                        },
                        .root_name = text,
                        .root_node = local.node,
                    },
                };
            }
            // not a local, so ordinary resolution gives the right message
            const value = try check.checkExpr(node, null);
            return check.placeOfValue(node, value, text);
        },
        .field_access => |access| {
            const base = try check.checkPlace(access.lhs) orelse return null;
            return check.placeField(node, base, access.name_token);
        },
        .deref => |operand| return check.placeThroughPointer(node, operand),
        .err => return null,
        else => {
            const value = try check.checkExpr(node, null);
            return check.placeOfValue(node, value, "this value");
        },
    }
}

fn placeOfValue(
    check: *Check,
    node: Node.Index,
    value: Value,
    name: []const u8,
) Allocator.Error!?Place {
    switch (value) {
        .poison, .diverged => return null,
        .constant, .runtime => {
            const reason: Place.Reason = if (std.mem.eql(u8, name, "this value"))
                .temporary
            else
                .let_bound;
            return .{
                .kind = .value,
                .ref = refOf(value),
                .type = check.typeOf(value),
                .mutable = false,
                .reason = reason,
                .root_name = name,
                .root_node = node,
            };
        },
        else => {
            try check.reportNotValue(node, value);
            return null;
        },
    }
}

/// The place `p.*` names, as mutable as `p` is.
fn placeThroughPointer(
    check: *Check,
    node: Node.Index,
    operand: Node.Index,
) Allocator.Error!?Place {
    const comp = check.comp;
    const value = try check.checkExpr(operand, null);
    switch (value) {
        .constant, .runtime => {},
        .poison, .diverged => return null,
        else => {
            try check.reportNotValue(operand, value);
            return null;
        },
    }

    const found = check.typeOf(value);
    if (found == .poison) return null;

    const pointer = switch (comp.pool.keyOf(found)) {
        .type_pointer => |it| it,
        else => {
            try check.fail(node, .{
                .code = .type_mismatch,
                .message = try comp.fmt("'.*' needs a pointer, and this is {s}", .{
                    try comp.typeName(found),
                }),
                .label = "not a pointer",
                .help = "'.*' reads what a pointer points at, and a field is reached with '.name'",
            });
            return null;
        },
    };
    return .{
        .kind = .address,
        .ref = refOf(value),
        .type = pointer.child,
        .mutable = pointer.mutable,
        .reason = if (pointer.mutable) .mutable else .{ .const_pointer = found },
        .root_name = "this pointer",
        .root_node = operand,
    };
}

/// One field step. Crossing a pointer resets mutability to the pointer's own.
fn placeField(
    check: *Check,
    node: Node.Index,
    base: Place,
    name_token: Token.Index,
) Allocator.Error!?Place {
    const comp = check.comp;
    switch (comp.pool.keyOf(base.type)) {
        .type_struct => |instance| {
            const row = try check.findField(instance, name_token) orelse return null;
            const row_type = comp.rowAt(row).type;

            const addressed = try check.placeAddress(base) orelse return null;
            const field_pointer = try check.pointerTo(row_type, addressed.mutable);
            const place = try check.emit(.field_ptr, field_pointer, .{
                .field = .{ .base = addressed.ref, .row = row },
            });
            return .{
                .kind = .address,
                .ref = place,
                .type = row_type,
                .mutable = addressed.mutable,
                .reason = addressed.reason,
                .root_name = addressed.root_name,
                .root_node = addressed.root_node,
            };
        },
        .type_pointer => |pointer| {
            switch (comp.pool.keyOf(pointer.child)) {
                .type_struct => |instance| {
                    const row = try check.findField(instance, name_token) orelse return null;
                    const row_type = comp.rowAt(row).type;

                    const through = try check.placeValue(base);
                    const field_pointer = try check.pointerTo(row_type, pointer.mutable);
                    const place = try check.emit(.field_ptr, field_pointer, .{
                        .field = .{ .base = through, .row = row },
                    });
                    return .{
                        .kind = .address,
                        .ref = place,
                        .type = row_type,
                        .mutable = pointer.mutable,
                        .reason = if (pointer.mutable)
                            .mutable
                        else
                            .{ .const_pointer = base.type },
                        .root_name = base.root_name,
                        .root_node = base.root_node,
                    };
                },
                else => {
                    try check.reportNoField(node, base.type, check.tree.tokenSlice(name_token));
                    return null;
                },
            }
        },
        else => {
            const text = check.tree.tokenSlice(name_token);
            try check.reportNoField(node, base.type, text);
            return null;
        },
    }
}

/// Loading when the place is an address.
fn placeValue(check: *Check, place: Place) Allocator.Error!Ref {
    return switch (place.kind) {
        .value => place.ref,
        .address => try check.emitOne(.load, place.type, place.ref),
    };
}

/// Spilling to a temporary. Unobservable, because only immutable values are
/// spilled.
fn placeAddress(check: *Check, place: Place) Allocator.Error!?Place {
    if (place.kind == .address) return place;
    if (place.type == .poison) return null;

    const slot = try check.emitSlot(.empty, place.type);
    try check.emitStore(slot, place.ref);
    return .{
        .kind = .address,
        .ref = slot,
        .type = place.type,
        .mutable = false,
        .reason = place.reason,
        .root_name = place.root_name,
        .root_node = place.root_node,
    };
}

fn reportImmutable(check: *Check, node: Node.Index, place: Place) Allocator.Error!void {
    const comp = check.comp;
    assert(place.mutable == false);

    const report: Compilation.Report = switch (place.reason) {
        .mutable => unreachable,
        .let_bound => .{
            .code = .not_assignable,
            .message = try comp.fmt("'{s}' was bound with 'let', so it cannot change", .{
                place.root_name,
            }),
            .label = "immutable",
            .help = "declare it 'var' if it needs to change",
            .notes = try comp.notes(&.{
                comp.noteAt(check.module_index, place.root_node, "bound here"),
            }),
        },
        .param_bound => .{
            .code = .not_assignable,
            .message = try comp.fmt(
                "'{s}' is a parameter, and a parameter is a copy that dies with the call",
                .{place.root_name},
            ),
            .label = "immutable",
            .help = "take '*var T' to write the caller's value, or copy it into a 'var' first",
        },
        .const_pointer => |crossed| report: {
            const child = comp.pool.keyOf(crossed).type_pointer.child;
            break :report .{
                .code = .write_through_pointer,
                .message = try comp.fmt("this writes through a '{s}', which is read-only", .{
                    try comp.typeName(crossed),
                }),
                .label = "read-only pointer",
                .help = try comp.fmt("take '*var {s}' to write through it", .{
                    try comp.typeName(child),
                }),
            };
        },
        .temporary => .{
            .code = .not_assignable,
            .message = "this value has no home, so there is nowhere to write",
            .label = "not a place",
        },
    };
    try check.fail(node, report);
}

fn moduleMember(
    check: *Check,
    target: Module.Index,
    node: Node.Index,
    name_token: Token.Index,
) Allocator.Error!?Decl.Index {
    const name_text = check.tree.tokenSlice(name_token);
    return Module.findExported(
        check.comp,
        target,
        name_text,
        .{ .module = check.module_index, .node = node },
        .{ .start = check.tree.tokenStart(name_token), .end = check.tree.tokenEnd(name_token) },
    );
}

// coercion and small shared answers

fn typeOf(check: *const Check, value: Value) Pool.Index {
    return switch (value) {
        .constant => |constant| check.comp.pool.typeOfValue(constant),
        .runtime => |runtime| runtime.type,
        .poison, .diverged => .poison,
        .named_type, .named_generic, .named_fn, .named_module, .named_intrinsic => .poison,
    };
}

fn runtimeValue(ref: Ref, type_index: Pool.Index) Value {
    return .{ .runtime = .{ .ref = ref, .type = type_index } };
}

/// Anything with no ref of its own becomes poison.
fn refOf(value: Value) Ref {
    return switch (value) {
        .constant => |constant| .fromConstant(constant),
        .runtime => |runtime| runtime.ref,
        .diverged, .poison => .fromConstant(.poison),
        .named_type, .named_generic, .named_fn, .named_module => .fromConstant(.poison),
        .named_intrinsic => .fromConstant(.poison),
    };
}

/// Whether a slot can be made of this.
fn typeCanHold(check: *const Check, type_index: Pool.Index) bool {
    if (type_index == .void_type) return false;
    if (type_index == .untyped_int_type) return false;
    if (type_index == .untyped_float_type) return false;
    return check.comp.pool.isType(type_index);
}

/// A statement wants void, the one hint that changes a shape.
fn wantsValue(hint: ?Pool.Index) bool {
    const wanted = hint orelse return true;
    return wanted != .void_type;
}

fn tagIsStatement(tag: Node.Tag) bool {
    return switch (tag) {
        .var_decl, .assign, .defer_stmt, .err => true,
        else => false,
    };
}

/// Constants are checked by value, `*var T` serves where `*T` is asked for,
/// and a union admits a value whose type it lists. Nothing else converts.
fn coerce(
    check: *Check,
    value: Value,
    wanted: Pool.Index,
    node: Node.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    if (wanted == .poison) return .poison;

    switch (value) {
        .poison => return .poison,
        .diverged => return .diverged,
        .constant => |constant| return check.fitValue(constant, wanted, node),
        .runtime => |runtime| {
            if (runtime.type == wanted) return value;
            if (runtime.type == .poison) return .poison;

            const have = comp.pool.keyOf(runtime.type);
            const want = comp.pool.keyOf(wanted);

            // the one subtyping edge
            if (have == .type_pointer and want == .type_pointer) {
                const compatible = have.type_pointer.child == want.type_pointer.child and
                    have.type_pointer.mutable and want.type_pointer.mutable == false;
                if (compatible) {
                    return runtimeValue(runtime.ref, wanted);
                }
                if (have.type_pointer.child == want.type_pointer.child) {
                    try check.fail(node, .{
                        .code = .write_through_pointer,
                        .message = try comp.fmt("this is {s}, and {s} is needed to write", .{
                            try comp.typeName(runtime.type),
                            try comp.typeName(wanted),
                        }),
                        .label = "read-only pointer",
                        .help = "take '*var' where the pointer is made",
                    });
                    return .poison;
                }
            }

            // membership is the whole conversion story for a union: a member
            // value becomes a union that lists it, and a union value becomes
            // a wider one that lists every member it may hold
            if (want == .type_union) {
                const listed = if (have == .type_union)
                    comp.pool.unionCovers(wanted, runtime.type)
                else
                    comp.pool.unionHas(wanted, runtime.type);
                if (listed) {
                    const wrapped = try check.emitOne(.union_init, wanted, runtime.ref);
                    return runtimeValue(wrapped, wanted);
                }
            }

            return check.reportMismatch(node, value, wanted);
        },
        else => {
            try check.reportNotValue(node, value);
            return .poison;
        },
    }
}

/// A constant meets a type by value.
fn fitValue(
    check: *Check,
    constant: Pool.Index,
    wanted: Pool.Index,
    node: Node.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    if (constant == .poison) return .poison;
    if (wanted == .poison) return .poison;

    return switch (try comp.pool.fit(comp.gpa, constant, wanted)) {
        .value => |final| .{ .constant = final },
        .does_not_fit => fitted: {
            try check.reportDoesNotFit(node, constant, wanted);
            break :fitted .poison;
        },
        .wrong_kind => try check.reportMismatch(node, .{ .constant = constant }, wanted),
    };
}

/// The result must stay a constant, for a top level binding.
fn fitConstant(
    check: *Check,
    constant: Pool.Index,
    wanted: Pool.Index,
    node: Node.Index,
) Allocator.Error!Pool.Index {
    const comp = check.comp;
    if (constant == .poison) return .poison;
    if (wanted == .poison) return .poison;

    const met = try comp.pool.fit(comp.gpa, constant, wanted);
    switch (met) {
        .value => |final| return final,
        .does_not_fit => {
            try check.reportDoesNotFit(node, constant, wanted);
            return .poison;
        },
        .wrong_kind => {
            _ = try check.reportMismatch(node, .{ .constant = constant }, wanted);
            return .poison;
        },
    }
}

fn reportDoesNotFit(
    check: *Check,
    node: Node.Index,
    constant: Pool.Index,
    wanted: Pool.Index,
) Allocator.Error!void {
    try check.fail(node, .{
        .code = .does_not_fit,
        .message = try check.comp.fmt("{s} does not fit in {s}", .{
            try check.comp.spellValue(constant),
            try check.comp.typeName(wanted),
        }),
        .label = "past the type's edge",
        .help = "a constant takes any type its value fits, and this value does not fit this one",
    });
}

fn reportMismatch(
    check: *Check,
    node: Node.Index,
    value: Value,
    wanted: Pool.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    const found = check.typeOf(value);
    const found_name = try comp.typeName(found);
    try check.fail(node, .{
        .code = .type_mismatch,
        .message = try comp.fmt("expected {s}, found {s}", .{
            try comp.typeName(wanted),
            found_name,
        }),
        .label = "the wrong type",
        .help = "nothing converts on its own",
    });
    return .poison;
}

fn valueOnly(check: *Check, node: Node.Index, value: Value) Allocator.Error!bool {
    switch (value) {
        .constant, .runtime, .poison, .diverged => return true,
        else => {
            try check.reportNotValue(node, value);
            return false;
        },
    }
}

fn runtimeOnly(tag: Node.Tag) ?[]const u8 {
    return switch (tag) {
        .if_expr => "an 'if'",
        .block => "a block",
        .return_expr => "'return'",
        .break_expr => "'break'",
        .continue_expr => "'continue'",
        .call => "a call",
        .struct_literal => "a struct literal",
        .deref => "reading through a pointer",
        else => null,
    };
}

fn needRuntime(check: *Check, node: Node.Index, what: []const u8) Allocator.Error!Value {
    assert(check.builder == null);
    try check.fail(node, .{
        .code = .not_constant,
        .message = try check.comp.fmt(
            "a top-level binding must be a constant, and {s} happens at run time",
            .{what},
        ),
        .label = "not a constant",
        .help = "the constant set is literals, names of constants, operators, and parentheses",
    });
    return .poison;
}

fn reportNotValue(check: *Check, node: Node.Index, value: Value) Allocator.Error!void {
    const report: Compilation.Report = switch (value) {
        .named_type, .named_generic => .{
            .code = .type_as_value,
            .message = "types are not values",
            .label = "a type, where a value belongs",
            .help = "a type appears in type positions, and as the base of a '.' access",
        },
        .named_fn => .{
            .code = .not_a_function,
            .message = "a function is not a value, so call it",
            .label = "missing the call",
            .help = "there are no function values in the language",
        },
        .named_module => .{
            .code = .type_as_value,
            .message = "a module is not a value",
            .label = "a module, where a value belongs",
        },
        .named_intrinsic => return check.failIntrinsicNotValue(node),
        // a value that never arrives is never complained about
        .constant, .runtime, .poison, .diverged => unreachable,
    };
    try check.fail(node, report);
}

fn reportBadOperand(
    check: *Check,
    op_token: Token.Index,
    operand_type: Pool.Index,
) Allocator.Error!void {
    try check.failToken(op_token, .{
        .code = .bad_operand,
        .message = try check.comp.fmt("'{s}' cannot be applied to {s}", .{
            check.tree.tokenSlice(op_token),
            try check.comp.typeName(operand_type),
        }),
        .label = "wrong operand type",
    });
}

fn reportUndefined(check: *Check, node: Node.Index, text: []const u8) Allocator.Error!void {
    try check.fail(node, .{
        .code = .undefined_name,
        .message = try check.comp.fmt("nothing named '{s}' is in scope here", .{text}),
        .label = "unknown name",
        .help = try check.suggestName(text),
    });
}

/// Among locals, type parameters, this file's declarations, and the prelude.
fn suggestName(check: *Check, text: []const u8) Allocator.Error!?[]const u8 {
    const comp = check.comp;
    var best: ?[]const u8 = null;
    var best_distance: u32 = 3;

    if (check.builder) |builder| {
        for (builder.locals.items) |local| {
            considerName(comp.pool.stringText(local.name), text, &best, &best_distance);
        }
    }
    for (check.bindings) |binding| {
        considerName(comp.pool.stringText(binding.name), text, &best, &best_distance);
    }
    const decls_end = check.module.decls.end();
    for (comp.decls.items[check.module.decls.start..decls_end]) |decl| {
        if (decl.owner != .none) continue;
        considerName(comp.pool.stringText(decl.name), text, &best, &best_distance);
    }
    for (Pool.prelude_names) |name| considerName(name, text, &best, &best_distance);

    const found = best orelse return null;
    return try comp.fmt("did you mean '{s}'?", .{found});
}

fn considerName(candidate: []const u8, text: []const u8, best: *?[]const u8, distance: *u32) void {
    const measured = edit_distance.between(text, candidate);
    if (measured < distance.*) {
        distance.* = measured;
        best.* = candidate;
    }
}

fn origin(check: *const Check, node: Node.Index) Compilation.Origin {
    return .{ .module = check.module_index, .node = node };
}

fn fail(check: *Check, node: Node.Index, report: Compilation.Report) Allocator.Error!void {
    try check.comp.reportNode(check.module_index, node, report);
}

fn failToken(check: *Check, token: Token.Index, report: Compilation.Report) Allocator.Error!void {
    try check.comp.reportToken(check.module_index, token, report);
}

/// Blocks nothing jumps to are dropped, then the body is committed.
fn finishFunc(check: *Check) Allocator.Error!void {
    const comp = check.comp;
    const builder = check.builder.?;
    const block_count = builder.blocks.items.len;
    assert(block_count > 0);

    var live = try std.DynamicBitSet.initEmpty(comp.gpa, block_count);
    defer live.deinit();

    var frontier: std.ArrayList(u32) = .empty;
    defer frontier.deinit(comp.gpa);
    try frontier.ensureTotalCapacity(comp.gpa, block_count);

    live.set(0);
    frontier.appendAssumeCapacity(0);
    while (frontier.pop()) |raw| {
        const block = builder.blocks.items[raw];
        assert(block.terminator != .none);
        switch (block.terminator) {
            .none => unreachable,
            .jump => |target| try finishFuncVisit(&live, &frontier, target.int()),
            .branch => |branch| {
                try finishFuncVisit(&live, &frontier, branch.then_block.int());
                try finishFuncVisit(&live, &frontier, branch.else_block.int());
            },
            .ret => {},
        }
    }

    // only blocks are renumbered, so every instruction ref stays valid
    var block_map = try comp.gpa.alloc(u32, block_count);
    defer comp.gpa.free(block_map);

    var live_blocks: u32 = 0;
    for (0..block_count) |raw| {
        if (live.isSet(raw)) {
            block_map[raw] = live_blocks;
            live_blocks += 1;
        } else {
            block_map[raw] = std.math.maxInt(u32);
        }
    }

    var blocks: std.ArrayList(IR.Block) = .empty;
    errdefer blocks.deinit(comp.gpa);
    try blocks.ensureTotalCapacity(comp.gpa, live_blocks);

    for (builder.blocks.items, 0..) |block, raw| {
        if (live.isSet(raw) == false) continue;
        blocks.appendAssumeCapacity(.{
            .first = block.first,
            .count = block.count,
            .terminator = switch (block.terminator) {
                .none => unreachable,
                .jump => |target| .{ .jump = @enumFromInt(block_map[target.int()]) },
                .branch => |branch| .{ .branch = .{
                    .cond = branch.cond,
                    .then_block = @enumFromInt(block_map[branch.then_block.int()]),
                    .else_block = @enumFromInt(block_map[branch.else_block.int()]),
                } },
                .ret => |value| .{ .ret = value },
            },
        });
    }
    assert(blocks.items.len == live_blocks);

    const extra = try comp.gpa.dupe(u32, builder.extra.items);
    errdefer comp.gpa.free(extra);
    const blocks_owned = try blocks.toOwnedSlice(comp.gpa);
    errdefer comp.gpa.free(blocks_owned);

    try comp.funcs.append(comp.gpa, .{
        .instance = builder.instance,
        .insts = builder.insts.toOwnedSlice(),
        .extra = extra,
        .blocks = blocks_owned,
    });
}

fn finishFuncVisit(
    live: *std.DynamicBitSet,
    frontier: *std.ArrayList(u32),
    target: u32,
) Allocator.Error!void {
    if (live.isSet(target)) return;
    live.set(target);
    frontier.appendAssumeCapacity(target);
}
