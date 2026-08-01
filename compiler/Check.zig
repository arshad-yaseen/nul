//! Lower to IR.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Compilation = @import("Compilation.zig");
const IR = @import("IR.zig");
const Module = @import("Module.zig");
const Pool = @import("Pool.zig");
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
/// Present while a function body is being built. Null means constants only.
builder: ?*Builder,
/// Field types skip the size demand, because their struct gets its own walk,
/// which must not re-enter the rows being built.
demand_sizes: bool,

const Check = @This();

const type_params_max = 16;
const call_args_max = 255;
const type_depth_max = AST.nest_max;

const Binding = struct { name: Pool.String, type: Pool.Index };

const Value = union(enum) {
    constant: Pool.Index,
    runtime: Runtime,
    /// Legal only as the base of a `.` access.
    type_ref: Pool.Index,
    /// A generic struct without its arguments.
    generic_ref: Decl.Index,
    /// Legal only as a callee or an instance base.
    fn_ref: Decl.Index,
    module_ref: Module.Index,
    builtin_ref,
    poison,

    const Runtime = struct { ref: Ref, type: Pool.Index };
};

// entry points, one per unit kind `ensure` dispatches

pub fn typeAlias(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    var check = context(comp, decl_index, &.{});
    const view = check.tree.viewOf(check.declNode(decl_index)).type_decl;

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
        met = try check.meetConstant(constant, annotation, view.init_expr);
    }

    comp.declPtr(decl_index).result = met.int();
    return met != .poison;
}

/// Fields into rows, with the type parameters bound to this instantiation.
pub fn structRows(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    var buffer: [type_params_max]Binding = undefined;
    const bindings = try bindTypeParams(comp, instance, &buffer) orelse return false;
    var check = context(comp, decl_index, bindings);
    check.demand_sizes = false;

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

/// A struct embedding itself by value has no size, which `ensure` reports at
/// the field that closes the loop.
pub fn structSize(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    const decl = comp.declAt(decl_index);
    const from: Compilation.Origin = .{ .module = decl.module, .node = decl.node };
    try comp.ensure(.of(.rows, instance), from);

    const rows = comp.instanceAt(instance).rows;
    for (rows.start..rows.end()) |raw| {
        // by index, because the walk below can grow the rows table
        const row = comp.rowAt(@intCast(raw));
        try sizeWalkType(comp, row.type, .{ .module = decl.module, .node = row.node }, 0);
    }
    return true;
}

/// The types a value embeds directly. A pointer breaks the chain, which is
/// what the size cycle help tells the author to add.
fn sizeWalkType(
    comp: *Compilation,
    type_index: Pool.Index,
    from: Compilation.Origin,
    depth: u32,
) Allocator.Error!void {
    if (depth >= type_depth_max) return;
    switch (comp.pool.keyOf(type_index)) {
        .struct_type => |embedded| try comp.ensure(.of(.size, embedded), from),
        .optional, .error_union => |child| try sizeWalkType(comp, child, from, depth + 1),
        .simple, .pointer => {},
        .int, .float, .error_value, .null_typed => unreachable,
    }
}

pub fn fnSignature(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    var buffer: [type_params_max]Binding = undefined;
    const bindings = try bindTypeParams(comp, instance, &buffer) orelse return false;
    var check = context(comp, decl_index, bindings);

    const view = check.tree.viewOf(check.declNode(decl_index)).fn_decl;

    // staged, because resolving a parameter type can build other rows
    const mark = comp.rows_scratch.items.len;
    defer comp.rows_scratch.shrinkRetainingCapacity(mark);

    var clean = true;
    var arena_param: ?Node.Index = null;
    for (view.params) |param_node| {
        if (check.tree.nodeTag(param_node) != .param) continue;
        const param = check.tree.viewOf(param_node).param;
        const name_text = check.tree.tokenSlice(param.name_token);

        const param_type = try check.resolveWrittenType(param.type_expr);
        if (param_type == .poison) clean = false;

        if (check.typeIsRegion(param_type)) {
            if (arena_param == null) {
                arena_param = param_node;
            } else {
                try check.fail(param_node, .{
                    .code = .two_arenas,
                    .message = "a function allocates from exactly one arena, and this is a second",
                    .label = "one too many",
                    .help = "for scratch local to this call, make a child inside instead; " ++
                        "for scratch shared across calls, store the arena in the collection " ++
                        "it fills and pass that",
                    .notes = try comp.notes(&.{
                        comp.noteAt(check.module_index, arena_param.?, "the first arena is here"),
                    }),
                });
                clean = false;
            }
        }

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
        .nothing_type;
    comp.instancePtr(instance).type = return_type;

    if (return_type == .poison) clean = false;
    return clean;
}

/// Arguments to type parameters, the owner first for a member.
fn bindTypeParams(
    comp: *Compilation,
    instance: Pool.Instance,
    buffer: *[type_params_max]Binding,
) Allocator.Error!?[]const Binding {
    const decl_index = comp.instanceDecl(instance);
    const decl = comp.declAt(decl_index);
    const args = comp.instanceArgs(instance);
    const tree = comp.treeOf(decl.module);

    var count: u32 = 0;
    if (decl.owner.unwrap()) |owner_index| {
        const owner = comp.declAt(owner_index);
        const owner_view = tree.viewOf(owner.node).struct_decl;
        for (owner_view.type_params) |param| {
            if (count == type_params_max) return tooManyTypeParams(comp, decl, param);
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
    for (own) |param| {
        if (count == type_params_max) return tooManyTypeParams(comp, decl, param);
        buffer[count] = .{
            .name = try comp.pool.string(comp.gpa, tree.tokenSlice(tree.nodeMainToken(param))),
            .type = args[count],
        };
        count += 1;
    }

    assert(count == args.len);
    return buffer[0..count];
}

fn tooManyTypeParams(
    comp: *Compilation,
    decl: Decl,
    param: Node.Index,
) Allocator.Error!?[]const Binding {
    try comp.reportNode(decl.module, param, .{
        .code = .generic_arguments,
        .message = try comp.fmt("a declaration takes at most {d} type parameters", .{
            type_params_max,
        }),
    });
    return null;
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
        .demand_sizes = true,
    };
}

fn declNode(check: *const Check, decl_index: Decl.Index) Node.Index {
    const decl = check.comp.declAt(decl_index);
    assert(decl.module == check.module_index);
    return decl.node;
}

// type expressions, where the type grammar meets the pool

/// A written type promises storage, so what it embeds by value must have a
/// size. Demanding one here is what finds a bottomless struct.
fn resolveWrittenType(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const resolved = try check.resolveType(node);
    if (check.demand_sizes and resolved != .poison) {
        try sizeWalkType(check.comp, resolved, check.origin(node), 0);
    }
    return resolved;
}

fn resolveType(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const comp = check.comp;

    switch (check.tree.viewOf(node)) {
        .ident => return check.resolveTypeName(node),
        .field_access => |access| {
            const base = try check.checkExpr(access.lhs, null);
            switch (base) {
                .module_ref => |target| {
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
        .instance => return check.resolveTypeInstance(node),
        .pointer_type => |pointer| {
            const child = try check.resolveType(pointer.child);
            if (child == .poison) return .poison;
            return comp.pool.intern(comp.gpa, .{
                .pointer = .{ .child = child, .mutable = pointer.is_mutable },
            });
        },
        .optional_type => |child_node| {
            const child = try check.resolveType(child_node);
            if (child == .poison) return .poison;
            return comp.pool.intern(comp.gpa, .{ .optional = child });
        },
        .error_union_type => |child_node| {
            const child = try check.resolveType(child_node);
            if (child == .poison) return .poison;
            if (check.tree.nodeTag(child_node) == .error_union_type) {
                try check.fail(node, .{
                    .code = .not_error_union,
                    .message = "an error union cannot hold another error union",
                    .label = "one '!' is enough",
                    .help = "there is one universal error set, so '!T' already covers every error",
                });
                return .poison;
            }
            return comp.pool.intern(comp.gpa, .{ .error_union = child });
        },
        .err => return .poison,
        // the parser builds only type nodes in type positions
        else => unreachable,
    }
}

fn pointerTo(check: *Check, child: Pool.Index, mutable: bool) Allocator.Error!Pool.Index {
    const comp = check.comp;
    return comp.pool.intern(comp.gpa, .{ .pointer = .{ .child = child, .mutable = mutable } });
}

fn resolveTypeName(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));

    for (check.bindings) |binding| {
        if (std.mem.eql(u8, check.comp.pool.stringText(binding.name), text)) {
            return binding.type;
        }
    }
    if (Pool.universalType(text)) |universal| return universal;

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
        .use => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            switch (Module.useTarget(comp, decl_index)) {
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
                .builtin => {
                    try check.failBuiltinMisuse(node);
                    return .poison;
                },
            }
        },
        .let, .fn_decl => {
            const what = if (decl.kind == .let) "a value" else "a function";
            try check.fail(node, .{
                .code = .not_a_type,
                .message = try comp.fmt("'{s}' is {s}, not a type", .{ name, what }),
                .label = "not a type",
            });
            return .poison;
        },
    }
}

fn resolveTypeInstance(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const comp = check.comp;
    const view = check.tree.viewOf(node).instance;

    const base = try check.checkExpr(view.base, null);
    const decl_index = switch (base) {
        .generic_ref => |decl_index| decl_index,
        .type_ref, .fn_ref => {
            try check.fail(node, .{
                .code = .generic_arguments,
                .message = if (base == .type_ref)
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
    for (view.args, 0..) |arg, position| {
        const resolved = try check.resolveType(arg);
        if (resolved == .poison) return .poison;
        args_buffer[position] = resolved;
    }

    const instance = try comp.instantiate(decl_index, args_buffer[0..view.args.len]);
    return comp.instanceType(instance);
}

/// A struct with a bound arena operation is the region type.
fn typeIsRegion(check: *const Check, type_index: Pool.Index) bool {
    const comp = check.comp;
    switch (comp.pool.keyOf(type_index)) {
        .struct_type => |instance| {
            const decl_index = comp.instanceDecl(instance);
            return comp.declAt(decl_index).is_region;
        },
        else => return false,
    }
}

/// Everything a body build carries. Blocks are contiguous runs, because one
/// is always finished before the next starts.
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
    /// Code in an unreachable block is still checked, then dropped.
    live: bool,

    const BlockBuild = struct { first: u32, count: u32, terminator: IR.Terminator };

    /// Where a field was given, `.none` for a call argument or a missing field.
    const Operand = struct { value: Value, initializer: Node.OptionalIndex };

    const Local = struct {
        name: Pool.String,
        node: Node.Index,
        kind: Kind,
        /// A ref, or a pool constant for `let_constant`.
        payload: u32,
        /// A `var_slot` ref is a pointer to this.
        type: Pool.Index,

        const Kind = enum(u8) { let_constant, let_value, var_slot, param, capture };
    };

    const Scope = struct {
        /// `.none` for a binding scope, which has no block and no arena.
        marker: Ref,
        locals_start: u32,
        defers_start: u32,
    };

    const Loop = struct {
        continue_target: IR.Block.Index,
        exit: IR.Block.Index,
        /// A `break` unwinds to here.
        scope: u32,
        /// Whether a reachable `break` targets the exit.
        broke: bool,
    };

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

/// One body into a `Func`. The signature is already resolved, so nothing here
/// changes what a caller sees.
pub fn fnBody(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    const decl = comp.declAt(decl_index);
    if (decl.builtin() != null) return true;
    if (comp.instanceAt(instance).rows_state != .done) return false;

    var buffer: [type_params_max]Binding = undefined;
    const bindings = try bindTypeParams(comp, instance, &buffer) orelse return false;
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
        .live = true,
    };
    defer builder.deinit(comp.gpa);
    check.builder = &builder;

    // one instruction per two source bytes of the body, measured on real code
    try builder.insts.ensureTotalCapacity(comp.gpa, 64);
    try builder.blocks.ensureTotalCapacity(comp.gpa, 8);

    const view = check.tree.viewOf(check.declNode(decl_index)).fn_decl;
    const entry = try check.newBlock();
    assert(entry == .entry);
    check.startBlock(entry);

    const rows = comp.instanceRows(instance);
    for (rows, 0..) |row, position| {
        const param_ref = try check.emit(.param, row.type, row.node, .{
            .param = .{ .name = row.name, .position = @intCast(position) },
        });
        try check.declareLocal(.{
            .name = row.name,
            .node = row.node,
            .kind = .param,
            .payload = @intFromEnum(param_ref),
            .type = row.type,
        }, row.node);
    }

    try check.pushScope(view.body);
    if (check.tree.nodeTag(view.body) == .block) {
        try check.checkBlockBody(view.body);
        if (check.blockOpen() and builder.live == false) {
            // past the last exit. seal it and let finish drop it
            check.endBlock(.{ .ret = .none });
        } else if (check.blockOpen()) {
            if (builder.return_type == .nothing_type) {
                try check.exitScopesDownTo(0, view.body);
                check.endBlock(.{ .ret = .none });
            } else {
                try check.failToken(view.name_token, .{
                    .code = .missing_return,
                    .message = try comp.fmt("not every path through '{s}' returns its {s}", .{
                        comp.pool.stringText(decl.name),
                        try comp.typeName(builder.return_type),
                    }),
                    .label = "a path falls off the end",
                    .help = "every path must end in 'return', or loop forever",
                });
                check.endBlock(.{ .ret = .none });
            }
        }
    } else {
        // an `= expr` body returns its expression
        const value = try check.checkExpr(view.body, builder.return_type);
        if (builder.return_type == .nothing_type) {
            try check.expectNothing(view.body, value);
            try check.exitScopesDownTo(0, view.body);
            check.endBlock(.{ .ret = .none });
        } else {
            const met = try check.coerce(value, builder.return_type, view.body);
            try check.exitScopesDownTo(0, view.body);
            check.endBlock(.{ .ret = refOf(met) });
        }
    }
    check.popScope();
    assert(builder.scopes.items.len == 0);

    try check.finishFunc();
    return true;
}

// blocks and instructions

fn emit(
    check: *Check,
    tag: IR.Inst.Tag,
    type_index: Pool.Index,
    node: Node.Index,
    data: IR.Inst.Data,
) Allocator.Error!Ref {
    const builder = check.builder.?;
    assert(builder.blocks.items[builder.current.int()].terminator == .none);

    if (builder.insts.len >= std.math.maxInt(u32) / 2) return error.OutOfMemory;
    const index: IR.Inst.Index = @enumFromInt(@as(u32, @intCast(builder.insts.len)));
    try builder.insts.append(check.comp.gpa, .{
        .tag = tag,
        .type = type_index,
        .node = node,
        .data = data,
    });
    return .fromInst(index);
}

fn emitOne(
    check: *Check,
    tag: IR.Inst.Tag,
    type_index: Pool.Index,
    node: Node.Index,
    operand: Ref,
) Allocator.Error!Ref {
    assert(operand != .none);
    return check.emit(tag, type_index, node, .{ .un = operand });
}

/// Producing the slot address. `.empty` names a checker temporary.
fn emitSlot(
    check: *Check,
    node: Node.Index,
    name: Pool.String,
    value_type: Pool.Index,
) Allocator.Error!Ref {
    const slot_type = try check.pointerTo(value_type, true);
    return check.emit(.local, slot_type, node, .{ .name = name });
}

fn emitStore(check: *Check, node: Node.Index, place: Ref, value: Ref) Allocator.Error!void {
    assert(place != .none);
    assert(value != .none);
    _ = try check.emit(.store, .nothing_type, node, .{ .bin = .{ .lhs = place, .rhs = value } });
}

fn newBlock(check: *Check) Allocator.Error!IR.Block.Index {
    const builder = check.builder.?;
    if (builder.blocks.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const index: IR.Block.Index = @enumFromInt(@as(u32, @intCast(builder.blocks.items.len)));
    try builder.blocks.append(check.comp.gpa, .{
        .first = 0,
        .count = 0,
        .terminator = .none,
    });
    return index;
}

fn startBlock(check: *Check, block: IR.Block.Index) void {
    const builder = check.builder.?;
    assert(builder.blocks.items[block.int()].terminator == .none);

    builder.blocks.items[block.int()].first = @intCast(builder.insts.len);
    builder.current = block;
}

fn endBlock(check: *Check, terminator: IR.Terminator) void {
    const builder = check.builder.?;
    const block = &builder.blocks.items[builder.current.int()];
    assert(terminator != .none);
    assert(block.terminator == .none);

    block.count = @as(u32, @intCast(builder.insts.len)) - block.first;
    block.terminator = terminator;
}

fn blockOpen(check: *const Check) bool {
    const builder = check.builder.?;
    return builder.blocks.items[builder.current.int()].terminator == .none;
}

// scopes, locals, and every way out

fn pushScope(check: *Check, node: Node.Index) Allocator.Error!void {
    const builder = check.builder.?;
    const marker = try check.emit(.scope_begin, .nothing_type, node, .{ .none = {} });
    try builder.scopes.append(check.comp.gpa, .{
        .marker = marker,
        .locals_start = @intCast(builder.locals.items.len),
        .defers_start = @intCast(builder.defer_nodes.items.len),
    });
}

/// Bindings only, a capture say. No marker, and nothing to emit on the way out.
fn pushBindingScope(check: *Check) Allocator.Error!void {
    const builder = check.builder.?;
    try builder.scopes.append(check.comp.gpa, .{
        .marker = .none,
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

/// Every scope from the innermost down to `target`, defers in reverse then the
/// scope end. Every way out goes through here, which is what makes `defer` one
/// feature rather than five sites.
fn exitScopesDownTo(check: *Check, target: u32, node: Node.Index) Allocator.Error!void {
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

        if (scope.marker != .none) {
            _ = try check.emitOne(.scope_end, .nothing_type, node, scope.marker);
        }
    }
}

fn emitDefer(check: *Check, node: Node.Index) Allocator.Error!void {
    const builder = check.builder.?;
    assert(builder.in_defer == false);

    builder.in_defer = true;
    defer builder.in_defer = false;
    const value = try check.checkExpr(node, null);
    try check.expectNothing(node, value);
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
        if (Pool.universalType(text) != null) {
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

fn checkBlockBody(check: *Check, node: Node.Index) Allocator.Error!void {
    assert(check.tree.nodeTag(node) == .block);
    const statements = check.tree.viewOf(node).block;
    for (statements, 0..) |statement, position| {
        if (check.blockOpen() == false or check.builder.?.live == false) {
            assert(position > 0);
            return check.reportUnreachable(statement, statements[position - 1]);
        }
        try check.checkStatement(statement);
    }
}

fn reportUnreachable(
    check: *Check,
    statement: Node.Index,
    exit: Node.Index,
) Allocator.Error!void {
    try check.fail(statement, .{
        .code = .unreachable_code,
        .message = "this cannot be reached",
        .label = "never runs",
        .notes = try check.comp.notes(&.{
            check.comp.noteAt(check.module_index, exit, "the block already left here"),
        }),
    });
}

fn checkScopedBlock(check: *Check, node: Node.Index) Allocator.Error!void {
    try check.pushScope(node);
    try check.checkBlockBody(node);
    if (check.blockOpen()) {
        try check.exitScopesDownTo(@intCast(check.builder.?.scopes.items.len - 1), node);
    }
    check.popScope();
}

fn checkStatement(check: *Check, node: Node.Index) Allocator.Error!void {
    assert(check.builder != null);

    switch (check.tree.viewOf(node)) {
        .var_decl => try check.checkVarDecl(node),
        .assign => |assign| try check.checkAssign(node, assign),
        .if_stmt => |view| try check.checkIf(view),
        .while_stmt => |view| try check.checkWhile(view),
        .return_stmt => |operand| try check.checkReturn(node, operand),
        .break_stmt => try check.checkBreakContinue(node, .breaking),
        .continue_stmt => try check.checkBreakContinue(node, .continuing),
        .defer_stmt => |expr| try check.checkDefer(expr),
        .err => {},
        else => {
            const value = try check.checkExpr(node, null);
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
            .message = "'_' cannot be bound; it is how a value is discarded",
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
                try check.meetOrWrap(constant, wanted, view.init_expr)
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
    if (value_type == .nothing_type) {
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
            .int, .float => true,
            .null_typed => false,
            .simple => |simple| simple == .null,
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

    const slot = try check.emitSlot(node, name, value_type);
    try check.emitStore(node, slot, refOf(final));
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

fn checkAssign(check: *Check, node: Node.Index, assign: AST.View.Pair) Allocator.Error!void {
    if (check.tree.nodeTag(assign.lhs) == .ident) {
        const text = check.tree.tokenSlice(check.tree.nodeMainToken(assign.lhs));
        if (std.mem.eql(u8, text, "_")) {
            // `_ = e` evaluates and drops on purpose, whatever the type
            const value = try check.checkExpr(assign.rhs, null);
            switch (value) {
                .constant, .runtime, .poison => {},
                else => try check.reportNotValue(assign.rhs, value),
            }
            return;
        }
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
    const value = try check.checkExpr(assign.rhs, place.type);
    const met = try check.coerce(value, place.type, assign.rhs);
    if (met == .poison) return;
    try check.emitStore(node, place.ref, refOf(met));
}

fn checkIf(check: *Check, view: AST.View.If) Allocator.Error!void {
    const builder = check.builder.?;
    const entry_live = builder.live;
    const then_block = try check.newBlock();
    const else_block = try check.newBlock();
    const join = try check.newBlock();

    if (view.capture.unwrap()) |capture| {
        const optional = try check.checkExpr(view.cond, null);
        const payload = try check.optionalPayload(view.cond, optional);
        const tested = refOf(optional);
        const has = try check.emitOne(.has_value, .bool_type, view.cond, tested);
        check.endBlock(.{ .branch = .{
            .cond = has,
            .then_block = then_block,
            .else_block = else_block,
        } });

        check.startBlock(then_block);
        try check.pushBindingScope();
        const unwrapped = try check.emitOne(.unwrap_value, payload, view.cond, tested);
        try check.bindCapture(capture, unwrapped, payload);
        try check.checkScopedBlock(view.then_block);
        check.popScope();
    } else {
        const cond = try check.checkCondition(view.cond);
        check.endBlock(.{ .branch = .{
            .cond = cond,
            .then_block = then_block,
            .else_block = else_block,
        } });
        check.startBlock(then_block);
        try check.checkScopedBlock(view.then_block);
    }
    var join_live = check.blockOpen() and builder.live;
    if (check.blockOpen()) check.endBlock(.{ .jump = join });

    check.startBlock(else_block);
    builder.live = entry_live;
    if (view.else_node.unwrap()) |else_node| {
        if (check.tree.nodeTag(else_node) == .if_stmt) {
            try check.checkIf(check.tree.viewOf(else_node).if_stmt);
        } else {
            try check.checkScopedBlock(else_node);
        }
        if (check.blockOpen() and builder.live) join_live = true;
        if (check.blockOpen()) check.endBlock(.{ .jump = join });
    } else {
        if (entry_live) join_live = true;
        check.endBlock(.{ .jump = join });
    }

    check.startBlock(join);
    builder.live = join_live;
}

fn checkWhile(check: *Check, view: AST.View.While) Allocator.Error!void {
    const builder = check.builder.?;
    const body_scope: u32 = @intCast(builder.scopes.items.len);
    const entry_live = builder.live;

    if (view.cond.unwrap()) |cond_node| {
        const cond_block = try check.newBlock();
        const body_block = try check.newBlock();
        const exit = try check.newBlock();
        check.endBlock(.{ .jump = cond_block });

        check.startBlock(cond_block);
        var tested: Ref = .none;
        var payload: Pool.Index = .poison;
        if (view.capture.unwrap() != null) {
            const optional = try check.checkExpr(cond_node, null);
            payload = try check.optionalPayload(cond_node, optional);
            tested = refOf(optional);
            const has = try check.emitOne(.has_value, .bool_type, cond_node, tested);
            check.endBlock(.{ .branch = .{
                .cond = has,
                .then_block = body_block,
                .else_block = exit,
            } });
        } else {
            const cond = try check.checkCondition(cond_node);
            check.endBlock(.{ .branch = .{
                .cond = cond,
                .then_block = body_block,
                .else_block = exit,
            } });
        }

        try builder.loops.append(check.comp.gpa, .{
            .continue_target = cond_block,
            .exit = exit,
            .scope = body_scope,
            .broke = false,
        });
        check.startBlock(body_block);
        builder.live = entry_live;
        try check.pushBindingScope();
        if (view.capture.unwrap()) |capture| {
            const unwrapped = try check.emitOne(.unwrap_value, payload, cond_node, tested);
            try check.bindCapture(capture, unwrapped, payload);
        }
        try check.checkScopedBlock(view.body);
        check.popScope();
        if (check.blockOpen()) check.endBlock(.{ .jump = cond_block });
        _ = builder.loops.pop();

        check.startBlock(exit);
        builder.live = entry_live;
    } else {
        // `while { }` has no condition, so the body head is the whole loop
        const body_block = try check.newBlock();
        const exit = try check.newBlock();
        check.endBlock(.{ .jump = body_block });

        try builder.loops.append(check.comp.gpa, .{
            .continue_target = body_block,
            .exit = exit,
            .scope = body_scope,
            .broke = false,
        });
        check.startBlock(body_block);
        builder.live = entry_live;
        try check.checkScopedBlock(view.body);
        if (check.blockOpen()) check.endBlock(.{ .jump = body_block });
        const loop = builder.loops.pop().?;

        // with no condition, only a `break` makes the far side real
        check.startBlock(exit);
        builder.live = loop.broke;
    }
}

fn checkCondition(check: *Check, node: Node.Index) Allocator.Error!Ref {
    const value = try check.checkExpr(node, null);
    const found = check.typeOf(value);
    if (found == .bool_type) return refOf(value);
    if (found == .poison) return .fromConstant(.poison);

    const optional = check.comp.pool.keyOf(found) == .optional;
    try check.fail(node, .{
        .code = .condition_not_bool,
        .message = try check.comp.fmt("this condition is {s}, not a bool", .{
            try check.comp.typeName(found),
        }),
        .label = "not a bool",
        .help = if (optional) "capture the payload instead: 'if x |v| { }'" else null,
    });
    return .fromConstant(.poison);
}

fn bindCapture(
    check: *Check,
    capture: Node.Index,
    ref: Ref,
    payload: Pool.Index,
) Allocator.Error!void {
    assert(check.tree.nodeTag(capture) == .capture);
    const token = check.tree.viewOf(capture).capture;
    const name = try check.comp.pool.string(check.comp.gpa, check.tree.tokenSlice(token));
    try check.declareLocal(.{
        .name = name,
        .node = capture,
        .kind = .capture,
        .payload = @intFromEnum(ref),
        .type = payload,
    }, capture);
}

/// Behind an optional condition, reporting when the value is not one.
fn optionalPayload(check: *Check, node: Node.Index, value: Value) Allocator.Error!Pool.Index {
    const found = check.typeOf(value);
    if (found == .poison) return .poison;
    switch (check.comp.pool.keyOf(found)) {
        .optional => |child| return child,
        else => {
            try check.fail(node, .{
                .code = .not_optional,
                .message = try check.comp.fmt("the capture needs an optional, and this is {s}", .{
                    try check.comp.typeName(found),
                }),
                .label = "nothing to unwrap",
            });
            return .poison;
        },
    }
}

fn checkReturn(check: *Check, node: Node.Index, operand: Node.OptionalIndex) Allocator.Error!void {
    const builder = check.builder.?;
    if (builder.in_defer) {
        try check.fail(node, .{
            .code = .defer_cannot_leave,
            .message = "a 'defer' runs on the way out, so it cannot leave again",
            .label = "no 'return' here",
        });
        return;
    }

    if (operand.unwrap()) |value_node| {
        if (builder.return_type == .nothing_type) {
            try check.fail(node, .{
                .code = .type_mismatch,
                .message = "this function returns nothing, and this 'return' carries a value",
                .label = "nothing expected",
                .help = "drop the value, or give the function a return type",
            });
            _ = try check.checkExpr(value_node, null);
            check.endBlock(.{ .ret = .none });
            return;
        }
        const value = try check.checkExpr(value_node, builder.return_type);
        const met = try check.coerce(value, builder.return_type, value_node);
        try check.exitScopesDownTo(0, node);
        check.endBlock(.{ .ret = refOf(met) });
        return;
    }

    if (builder.return_type != .nothing_type) {
        try check.fail(node, .{
            .code = .type_mismatch,
            .message = try check.comp.fmt("'return' here must carry a {s}", .{
                try check.comp.typeName(builder.return_type),
            }),
            .label = "returns nothing",
        });
    }
    try check.exitScopesDownTo(0, node);
    check.endBlock(.{ .ret = .none });
}

const LoopExit = enum { breaking, continuing };

fn checkBreakContinue(check: *Check, node: Node.Index, exit: LoopExit) Allocator.Error!void {
    const builder = check.builder.?;
    if (builder.in_defer) {
        try check.fail(node, .{
            .code = .defer_cannot_leave,
            .message = "a 'defer' runs on the way out, so it cannot leave again",
            .label = "not allowed here",
        });
        return;
    }
    if (builder.loops.items.len == 0) {
        try check.fail(node, .{
            .code = .outside_loop,
            .message = "there is no loop here to leave",
            .label = "outside every loop",
        });
        return;
    }

    const loop = &builder.loops.items[builder.loops.items.len - 1];
    try check.exitScopesDownTo(loop.scope, node);
    switch (exit) {
        .breaking => {
            if (builder.live) loop.broke = true;
            check.endBlock(.{ .jump = loop.exit });
        },
        .continuing => check.endBlock(.{ .jump = loop.continue_target }),
    }
}

/// Checked once here and rolled back, then emitted at every scope exit. The
/// rollback still reports a scope that never exits cleanly, and one report per
/// spot drops what the exits would duplicate.
fn checkDefer(check: *Check, expr: Node.Index) Allocator.Error!void {
    const builder = check.builder.?;
    const insts_mark = builder.insts.len;
    const extra_mark = builder.extra.items.len;
    const blocks_mark = builder.blocks.items.len;
    const locals_mark = builder.locals.items.len;
    const current = builder.current;

    try check.emitDefer(expr);

    builder.insts.shrinkRetainingCapacity(insts_mark);
    builder.extra.shrinkRetainingCapacity(extra_mark);
    builder.blocks.shrinkRetainingCapacity(blocks_mark);
    builder.locals.shrinkRetainingCapacity(locals_mark);
    builder.current = current;
    builder.blocks.items[current.int()].terminator = .none;
    builder.blocks.items[current.int()].count = 0;

    try builder.defer_nodes.append(check.comp.gpa, expr);
}

/// A statement expression must amount to nothing.
fn expectNothing(check: *Check, node: Node.Index, value: Value) Allocator.Error!void {
    switch (value) {
        .poison => return,
        .runtime => |runtime| {
            if (runtime.type == .nothing_type) return;
            if (runtime.type == .poison) return;
            if (check.comp.pool.keyOf(runtime.type) == .error_union) {
                try check.fail(node, .{
                    .code = .error_ignored,
                    .message = "this can fail, and nothing here handles it",
                    .label = "an unhandled error",
                    .help = "'try' passes it up, 'catch' handles it, and '_ =' drops it on purpose",
                });
                return;
            }
            try check.fail(node, .{
                .code = .value_unused,
                .message = try check.comp.fmt("this {s} goes nowhere", .{
                    try check.comp.typeName(runtime.type),
                }),
                .label = "unused value",
                .help = "bind it, or drop it on purpose with '_ ='",
            });
        },
        .constant => {
            try check.fail(node, .{
                .code = .value_unused,
                .message = "this value goes nowhere",
                .label = "unused value",
                .help = "bind it, or drop it on purpose with '_ ='",
            });
        },
        else => try check.reportNotValue(node, value),
    }
}

// expressions

fn checkExpr(check: *Check, node: Node.Index, hint: ?Pool.Index) Allocator.Error!Value {
    const comp = check.comp;

    switch (check.tree.viewOf(node)) {
        .ident => return check.checkIdent(node),
        .number_literal => return check.checkNumber(node),
        .bool_literal => |view| {
            return .{ .constant = if (view.value) .true_value else .false_value };
        },
        .null_literal => return .{ .constant = .null_value },
        .error_value => |token| {
            const name = try comp.pool.string(comp.gpa, check.tree.tokenSlice(token));
            return .{ .constant = try comp.pool.intern(comp.gpa, .{ .error_value = name }) };
        },
        .grouped => |inner| return check.checkExpr(inner, hint),
        .binary => |view| return check.checkBinary(node, view),
        .unary => |view| return check.checkUnary(node, view),
        .field_access => |view| return check.checkFieldAccess(node, view),
        .call => return check.checkCall(node),
        .instance => |view| return check.checkInstanceExpr(node, view),
        .struct_literal => return check.checkStructLiteral(node, hint),
        .try_expr => |operand| return check.checkTry(node, operand),
        .orelse_expr => |view| return check.checkOrelse(node, view),
        .catch_expr => |view| return check.checkCatch(node, view),
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
            .message = "'_' has no value; it only discards one",
            .label = "not a value",
        });
        return .poison;
    }

    if (check.findLocal(text)) |local| {
        switch (local.kind) {
            .let_constant => return .{ .constant = @enumFromInt(local.payload) },
            .let_value, .param, .capture => return .{ .runtime = .{
                .ref = @enumFromInt(local.payload),
                .type = local.type,
            } },
            .var_slot => {
                const slot: Ref = @enumFromInt(local.payload);
                const loaded = try check.emitOne(.load, local.type, node, slot);
                return .{ .runtime = .{ .ref = loaded, .type = local.type } };
            },
        }
    }

    for (check.bindings) |binding| {
        if (std.mem.eql(u8, comp.pool.stringText(binding.name), text)) {
            return .{ .type_ref = binding.type };
        }
    }

    if (Pool.universalType(text)) |universal| return .{ .type_ref = universal };

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
        .fn_decl => return .{ .fn_ref = decl_index },
        .struct_decl => {
            if (comp.typeParamCount(decl_index) > 0) return .{ .generic_ref = decl_index };
            const instance = try comp.instantiate(decl_index, &.{});
            return .{ .type_ref = comp.instanceType(instance) };
        },
        .type_alias => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            return .{ .type_ref = @enumFromInt(comp.declAt(decl_index).result) };
        },
        .use => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            switch (Module.useTarget(comp, decl_index)) {
                .module => |target| return .{ .module_ref = target },
                .decl => |target| return check.declAsValue(target, node),
                .builtin => return .builtin_ref,
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
            .float = .{ .type = .untyped_float_type, .value = value },
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
        .int = .{ .type = .untyped_int_type, .value = value },
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

fn checkBinary(check: *Check, node: Node.Index, view: AST.View.Binary) Allocator.Error!Value {
    if (view.op == .bool_and or view.op == .bool_or) {
        return check.checkShortCircuit(node, view);
    }

    const lhs = try check.checkExpr(view.lhs, null);
    const rhs = try check.checkExpr(view.rhs, null);
    if (lhs == .poison or rhs == .poison) return .poison;
    if (try check.valueOnly(view.lhs, lhs) == false) return .poison;
    if (try check.valueOnly(view.rhs, rhs) == false) return .poison;

    if (lhs == .constant and rhs == .constant) {
        return check.foldBinary(view, lhs.constant, rhs.constant);
    }
    return check.emitBinary(node, view, lhs, rhs);
}

/// The folding core answers, and every edge is reported at the operator.
fn foldBinary(
    check: *Check,
    view: AST.View.Binary,
    lhs: Pool.Index,
    rhs: Pool.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    const folded = try comp.pool.fold(comp.gpa, view.op, lhs, rhs);
    switch (folded) {
        .value => |value| return .{ .constant = value },
        .overflow => {
            try check.failToken(view.op_token, .{
                .code = .overflow,
                .message = "this overflows the 128 bits constants fold in",
                .label = "too large",
            });
            return .poison;
        },
        .division_by_zero => {
            try check.failToken(view.op_token, .{
                .code = .division_by_zero,
                .message = "this divides by zero",
                .label = "the divisor is zero",
            });
            return .poison;
        },
        .does_not_fit => |missed| {
            try check.failToken(view.op_token, .{
                .code = .does_not_fit,
                .message = try comp.fmt("{d} does not fit in {s}", .{
                    missed.value,
                    try comp.typeName(missed.type),
                }),
                .label = "past the type's edge",
            });
            return .poison;
        },
        .mismatch => |pair| {
            try check.failToken(view.op_token, .{
                .code = .mixed_types,
                .message = try comp.fmt("'{t}' mixes {s} and {s}", .{
                    view.op,
                    try comp.typeName(pair.left),
                    try comp.typeName(pair.right),
                }),
                .label = "two different types",
                .help = "nothing converts on its own; give both sides one type",
            });
            return .poison;
        },
        .bad_operand => |operand_type| {
            try check.reportBadOperand(view.op_token, view.op, operand_type);
            return .poison;
        },
    }
}

fn emitBinary(
    check: *Check,
    node: Node.Index,
    view: AST.View.Binary,
    lhs_in: Value,
    rhs_in: Value,
) Allocator.Error!Value {
    const comp = check.comp;
    var lhs = lhs_in;
    var rhs = rhs_in;

    // a constant takes the runtime side's type where they meet
    if (lhs == .constant) lhs = try check.coerce(lhs, check.typeOf(rhs), view.lhs);
    if (rhs == .constant) rhs = try check.coerce(rhs, check.typeOf(lhs), view.rhs);
    if (lhs == .poison or rhs == .poison) return .poison;

    const left = check.typeOf(lhs);
    const right = check.typeOf(rhs);
    if (left != right) {
        try check.failToken(view.op_token, .{
            .code = .mixed_types,
            .message = try comp.fmt("'{t}' mixes {s} and {s}", .{
                view.op,
                try comp.typeName(left),
                try comp.typeName(right),
            }),
            .label = "two different types",
            .help = "nothing converts on its own; give both sides one type",
        });
        return .poison;
    }

    const admissible = switch (view.op) {
        .add, .sub, .mul, .div => Pool.isNumeric(left),
        .mod => Pool.isInteger(left),
        .less_than, .less_or_equal, .greater_than, .greater_or_equal => Pool.isNumeric(left),
        .equal, .not_equal => Pool.isNumeric(left) or left == .bool_type or
            left == .error_type,
        .bool_and, .bool_or => unreachable,
    };
    if (admissible == false) {
        try check.reportBadOperand(view.op_token, view.op, left);
        return .poison;
    }

    const tag: IR.Inst.Tag = switch (view.op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .equal => .cmp_eq,
        .not_equal => .cmp_ne,
        .less_than => .cmp_lt,
        .less_or_equal => .cmp_le,
        .greater_than => .cmp_gt,
        .greater_or_equal => .cmp_ge,
        .bool_and, .bool_or => unreachable,
    };
    const result_type: Pool.Index = switch (view.op) {
        .add, .sub, .mul, .div, .mod => left,
        else => .bool_type,
    };
    const result = try check.emit(tag, result_type, node, .{
        .bin = .{ .lhs = refOf(lhs), .rhs = refOf(rhs) },
    });
    return .{ .runtime = .{ .ref = result, .type = result_type } };
}

/// `and` and `or` are control flow. The right side runs only when the left
/// leaves the answer open, so the lowering is a branch and a temporary.
fn checkShortCircuit(check: *Check, node: Node.Index, view: AST.View.Binary) Allocator.Error!Value {
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
            // the answer is the left side. the right is still checked, into a
            // block nothing jumps to, so it leaves no trace
            try check.checkIntoDeadBlock(view.rhs);
            return lhs_met;
        }
        const rhs = try check.checkExpr(view.rhs, null);
        return check.coerce(rhs, .bool_type, view.rhs);
    }

    const slot = try check.emitSlot(node, .empty, .bool_type);
    try check.emitStore(node, slot, refOf(lhs_met));

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
    try check.emitStore(node, slot, refOf(rhs_met));
    check.endBlock(.{ .jump = join });

    check.startBlock(join);
    const loaded = try check.emitOne(.load, .bool_type, node, slot);
    return .{ .runtime = .{ .ref = loaded, .type = .bool_type } };
}

fn checkIntoDeadBlock(check: *Check, node: Node.Index) Allocator.Error!void {
    const resume_block = try check.newBlock();
    check.endBlock(.{ .jump = resume_block });

    const dead = try check.newBlock();
    check.startBlock(dead);
    _ = try check.checkExpr(node, null);
    check.endBlock(.{ .ret = .none });

    check.startBlock(resume_block);
}

fn checkUnary(check: *Check, node: Node.Index, view: AST.View.Unary) Allocator.Error!Value {
    const comp = check.comp;
    switch (view.op) {
        .address_of => {
            try check.fail(node, .{
                .code = .address_position,
                .message = "'&' can only appear as a call argument",
                .label = "not an argument here",
                .help = "a borrowed address cannot be stored, returned, or named, " ++
                    "so it never outlives the call",
            });
            return .poison;
        },
        .negate => {
            const operand = try check.checkExpr(view.operand, null);
            if (operand == .poison) return .poison;
            if (try check.valueOnly(view.operand, operand) == false) return .poison;

            if (operand == .constant) {
                const folded = try comp.pool.foldNegate(comp.gpa, operand.constant);
                return check.foldUnaryResult(view.op_token, folded);
            }
            const found = check.typeOf(operand);
            const signed = switch (found) {
                .i8_type, .i16_type, .i32_type, .i64_type => true,
                .f32_type, .f64_type => true,
                else => false,
            };
            if (signed == false) {
                try check.failToken(view.op_token, .{
                    .code = .bad_operand,
                    .message = try comp.fmt("'-' needs a signed number, and this is {s}", .{
                        try comp.typeName(found),
                    }),
                    .label = "cannot be negated",
                });
                return .poison;
            }
            const result = try check.emitOne(.negate, found, node, refOf(operand));
            return .{ .runtime = .{ .ref = result, .type = found } };
        },
        .bool_not => {
            const operand = try check.checkExpr(view.operand, null);
            if (operand == .poison) return .poison;
            if (try check.valueOnly(view.operand, operand) == false) return .poison;

            if (operand == .constant) {
                return check.foldUnaryResult(view.op_token, comp.pool.foldNot(operand.constant));
            }
            const met = try check.coerce(operand, .bool_type, view.operand);
            if (met == .poison) return .poison;
            const result = try check.emitOne(.not, .bool_type, node, refOf(met));
            return .{ .runtime = .{ .ref = result, .type = .bool_type } };
        },
    }
}

fn foldUnaryResult(check: *Check, op_token: Token.Index, folded: Pool.Fold) Allocator.Error!Value {
    switch (folded) {
        .value => |value| return .{ .constant = value },
        .overflow => {
            try check.failToken(op_token, .{
                .code = .overflow,
                .message = "this overflows the 128 bits constants fold in",
                .label = "too large",
            });
            return .poison;
        },
        .bad_operand => |operand_type| {
            try check.failToken(op_token, .{
                .code = .bad_operand,
                .message = try check.comp.fmt("this cannot be applied to {s}", .{
                    try check.comp.typeName(operand_type),
                }),
                .label = "wrong operand",
            });
            return .poison;
        },
        .division_by_zero, .does_not_fit, .mismatch => unreachable,
    }
}

fn checkTry(check: *Check, node: Node.Index, operand: Node.Index) Allocator.Error!Value {
    const comp = check.comp;
    const builder = check.builder orelse return check.needRuntime(node, "'try'");

    if (builder.in_defer) {
        try check.fail(node, .{
            .code = .defer_cannot_leave,
            .message = "a 'defer' runs on the way out, so 'try' cannot leave from inside one",
            .label = "no 'try' here",
            .help = "handle the error in the defer with 'catch'",
        });
        _ = try check.checkExpr(operand, null);
        return .poison;
    }

    const value = try check.checkExpr(operand, null);
    if (value == .poison) return .poison;
    const found = check.typeOf(value);
    const payload = switch (comp.pool.keyOf(found)) {
        .error_union => |child| child,
        else => {
            try check.fail(operand, .{
                .code = .not_error_union,
                .message = try comp.fmt("'try' needs a value that can fail, and this is {s}", .{
                    try comp.typeName(found),
                }),
                .label = "cannot fail",
                .help = "drop the 'try'",
            });
            return .poison;
        },
    };

    const returns = comp.pool.keyOf(builder.return_type);
    if (returns != .error_union) {
        try check.fail(node, .{
            .code = .try_needs_error_return,
            .message = "'try' passes the error up, but this function cannot fail",
            .label = "nowhere to send the error",
            .help = try comp.fmt("declare the return type '!{s}'", .{
                try comp.typeName(builder.return_type),
            }),
        });
        return .poison;
    }

    const tested = refOf(value);
    const is_error = try check.emitOne(.is_error, .bool_type, node, tested);
    const propagate = try check.newBlock();
    const ok_block = try check.newBlock();
    check.endBlock(.{ .branch = .{
        .cond = is_error,
        .then_block = propagate,
        .else_block = ok_block,
    } });

    check.startBlock(propagate);
    const caught = try check.emitOne(.unwrap_err, .error_type, node, tested);
    // the propagation path is a way out, so every live defer runs on it
    try check.exitScopesDownTo(0, node);
    const wrapped = try check.emitOne(.wrap_err, builder.return_type, node, caught);
    check.endBlock(.{ .ret = wrapped });

    check.startBlock(ok_block);
    const unwrapped = try check.emitOne(.unwrap_ok, payload, node, tested);
    return .{ .runtime = .{ .ref = unwrapped, .type = payload } };
}

fn checkOrelse(check: *Check, node: Node.Index, view: AST.View.Pair) Allocator.Error!Value {
    const comp = check.comp;
    const lhs = try check.checkExpr(view.lhs, null);
    if (lhs == .poison) return .poison;
    if (check.builder == null) return check.needRuntime(node, "'orelse'");

    // a constant left side is always `null`, so the answer is the right side
    if (lhs == .constant) {
        const key = comp.pool.keyOf(lhs.constant);
        const is_null = key == .null_typed or (key == .simple and key.simple == .null);
        if (is_null == false) {
            try check.fail(view.lhs, .{
                .code = .not_optional,
                .message = "'orelse' needs an optional on its left",
                .label = "never null",
            });
            return .poison;
        }
        if (check.tree.nodeTag(view.rhs) == .block) {
            try check.checkScopedBlock(view.rhs);
            if (check.blockOpen()) {
                return .{ .runtime = .{ .ref = refOf(lhs), .type = .nothing_type } };
            }
            const rest = try check.newBlock();
            check.startBlock(rest);
            check.builder.?.live = false;
            return .poison;
        }
        return check.checkExpr(view.rhs, null);
    }

    return check.checkRescue(node, .{
        .kind = .optional,
        .lhs = lhs,
        .lhs_node = view.lhs,
        .rhs = view.rhs,
        .capture = .none,
    });
}

fn checkCatch(check: *Check, node: Node.Index, view: AST.View.Catch) Allocator.Error!Value {
    const lhs = try check.checkExpr(view.lhs, null);
    if (lhs == .poison) return .poison;
    if (check.builder == null) return check.needRuntime(node, "'catch'");
    if (try check.valueOnly(view.lhs, lhs) == false) return .poison;

    return check.checkRescue(node, .{
        .kind = .error_union,
        .lhs = lhs,
        .lhs_node = view.lhs,
        .rhs = view.rhs,
        .capture = view.capture,
    });
}

/// `a orelse b` and `a catch b`, which are one lowering over two wrappers.
const Rescue = struct {
    kind: Kind,
    lhs: Value,
    lhs_node: Node.Index,
    rhs: Node.Index,
    capture: Node.OptionalIndex,

    const Kind = enum { optional, error_union };
};

/// A branch on the left, a payload arm, and a fallback arm. The fallback is a
/// value to store, or a block that hands the payload over by leaving the scope
/// and amounts to nothing by falling through.
fn checkRescue(check: *Check, node: Node.Index, rescue: Rescue) Allocator.Error!Value {
    const found = check.typeOf(rescue.lhs);
    const payload = check.rescuePayload(rescue.kind, found) orelse {
        try check.reportRescue(rescue.kind, rescue.lhs_node, found);
        return .poison;
    };

    const unwrap: IR.Inst.Tag = switch (rescue.kind) {
        .optional => .unwrap_value,
        .error_union => .unwrap_ok,
    };
    const tested = refOf(rescue.lhs);
    const cond = try check.emitOne(switch (rescue.kind) {
        .optional => .has_value,
        .error_union => .is_error,
    }, .bool_type, node, tested);

    const payload_block = try check.newBlock();
    const fallback_block = try check.newBlock();
    // `has_value` names the payload side, `is_error` names the fallback side
    const branch: IR.Terminator = .{ .branch = switch (rescue.kind) {
        .optional => .{
            .cond = cond,
            .then_block = payload_block,
            .else_block = fallback_block,
        },
        .error_union => .{
            .cond = cond,
            .then_block = fallback_block,
            .else_block = payload_block,
        },
    } };

    if (check.tree.nodeTag(rescue.rhs) == .block) {
        check.endBlock(branch);

        check.startBlock(fallback_block);
        try check.pushBindingScope();
        try check.bindCaught(rescue.capture, node, tested);
        try check.checkScopedBlock(rescue.rhs);
        check.popScope();
        if (check.blockOpen()) {
            const join = try check.newBlock();
            check.endBlock(.{ .jump = join });
            check.startBlock(payload_block);
            check.endBlock(.{ .jump = join });
            check.startBlock(join);
            return .{ .runtime = .{ .ref = tested, .type = .nothing_type } };
        }

        check.startBlock(payload_block);
        const unwrapped = try check.emitOne(unwrap, payload, node, tested);
        return .{ .runtime = .{ .ref = unwrapped, .type = payload } };
    }

    const slot = try check.emitSlot(node, .empty, payload);
    const join = try check.newBlock();
    check.endBlock(branch);

    check.startBlock(payload_block);
    const unwrapped = try check.emitOne(unwrap, payload, node, tested);
    try check.emitStore(node, slot, unwrapped);
    check.endBlock(.{ .jump = join });

    check.startBlock(fallback_block);
    try check.pushBindingScope();
    try check.bindCaught(rescue.capture, node, tested);
    const fallback = try check.checkExpr(rescue.rhs, payload);
    const met = try check.coerce(fallback, payload, rescue.rhs);
    check.popScope();
    try check.emitStore(node, slot, refOf(met));
    check.endBlock(.{ .jump = join });

    check.startBlock(join);
    const loaded = try check.emitOne(.load, payload, node, slot);
    return .{ .runtime = .{ .ref = loaded, .type = payload } };
}

fn rescuePayload(check: *const Check, kind: Rescue.Kind, found: Pool.Index) ?Pool.Index {
    return switch (check.comp.pool.keyOf(found)) {
        .optional => |child| if (kind == .optional) child else null,
        .error_union => |child| if (kind == .error_union) child else null,
        else => null,
    };
}

fn reportRescue(
    check: *Check,
    kind: Rescue.Kind,
    node: Node.Index,
    found: Pool.Index,
) Allocator.Error!void {
    const comp = check.comp;
    try check.fail(node, switch (kind) {
        .optional => .{
            .code = .not_optional,
            .message = try comp.fmt("'orelse' needs an optional, and this is {s}", .{
                try comp.typeName(found),
            }),
            .label = "never null",
            .help = "drop the 'orelse'",
        },
        .error_union => .{
            .code = .not_error_union,
            .message = try comp.fmt("'catch' needs a value that can fail, and this is {s}", .{
                try comp.typeName(found),
            }),
            .label = "cannot fail",
            .help = "drop the 'catch'",
        },
    });
}

/// The `|err|` of a `catch`. Nothing to bind for an `orelse`.
fn bindCaught(
    check: *Check,
    capture: Node.OptionalIndex,
    node: Node.Index,
    tested: Ref,
) Allocator.Error!void {
    const bound = capture.unwrap() orelse return;
    const caught = try check.emitOne(.unwrap_err, .error_type, node, tested);
    try check.bindCapture(bound, caught, .error_type);
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
        .module_ref => |target| {
            const member = try check.moduleMember(target, node, view.name_token) orelse
                return .poison;
            return check.declAsValue(member, node);
        },
        .builtin_ref => {
            try check.failBuiltinMisuse(node);
            return .poison;
        },
        .type_ref, .generic_ref => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = try comp.fmt("'{s}' is reached through a value or called; " ++
                    "it cannot be read", .{name_text}),
                .label = "not a value",
            });
            return .poison;
        },
        .fn_ref => {
            try check.fail(node, .{
                .code = .no_such_member,
                .message = "a function has no fields; call it first",
                .label = "'.' on a function",
            });
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
        .struct_type => |instance| {
            const row = try check.findField(instance, view.name_token) orelse return .poison;
            const row_type = comp.rowAt(row).type;
            const result = try check.emit(.field_val, row_type, node, .{
                .field = .{ .base = refOf(base), .row = row },
            });
            return .{ .runtime = .{ .ref = result, .type = row_type } };
        },
        .pointer => |pointer| {
            switch (comp.pool.keyOf(pointer.child)) {
                .struct_type => |instance| {
                    const row = try check.findField(instance, view.name_token) orelse
                        return .poison;
                    const row_type = comp.rowAt(row).type;
                    const field_pointer = try check.pointerTo(row_type, pointer.mutable);
                    const place = try check.emit(.field_ptr, field_pointer, node, .{
                        .field = .{ .base = refOf(base), .row = row },
                    });
                    const loaded = try check.emitOne(.load, row_type, node, place);
                    return .{ .runtime = .{ .ref = loaded, .type = row_type } };
                },
                else => {},
            }
            try check.reportNoField(node, found, name_text);
            return .poison;
        },
        .optional => {
            try check.fail(node, .{
                .code = .optional_not_unwrapped,
                .message = try comp.fmt("this is {s}; reach inside it first", .{
                    try comp.typeName(found),
                }),
                .label = "may be null",
                .help = "'if x |v| { }' and 'x orelse ...' unwrap an optional",
            });
            return .poison;
        },
        .error_union => {
            try check.fail(node, .{
                .code = .not_error_union,
                .message = try comp.fmt("this is {s}; it can still fail", .{
                    try comp.typeName(found),
                }),
                .label = "handle the error first",
                .help = "'try' passes the error up, 'catch' handles it here",
            });
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

/// With a suggestion when the name misses, and a hint when it names a method.
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
            .message = try comp.fmt("'{s}' is a function; call it: '.{s}(...)'", .{
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

fn findMember(comp: *const Compilation, decl_index: Decl.Index, name_text: []const u8) ?Decl.Index {
    const decl = comp.declAt(decl_index);
    assert(decl.kind == .struct_decl);

    const members = decl.members();
    for (members.start..members.start + members.len) |raw| {
        const member = comp.declAt(@enumFromInt(@as(u32, @intCast(raw))));
        if (member.kind != .fn_decl) continue;
        if (std.mem.eql(u8, comp.pool.stringText(member.name), name_text)) {
            return @enumFromInt(@as(u32, @intCast(raw)));
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

fn checkInstanceExpr(
    check: *Check,
    node: Node.Index,
    view: AST.View.Instance,
) Allocator.Error!Value {
    const base = try check.checkExpr(view.base, null);
    switch (base) {
        .generic_ref => {
            const resolved = try check.resolveTypeInstance(node);
            if (resolved == .poison) return .poison;
            return .{ .type_ref = resolved };
        },
        .fn_ref => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = "a function with its type arguments is still not a value; call it",
                .label = "missing the call",
            });
            return .poison;
        },
        .poison => return .poison,
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

/// Type from context. Every field named, every field present, no other form.
fn checkStructLiteral(check: *Check, node: Node.Index, hint: ?Pool.Index) Allocator.Error!Value {
    const comp = check.comp;
    const inits = check.tree.viewOf(node).struct_literal;

    // the context may be ?T or !T around the struct. `coerce` wraps on the way
    // back out
    var wanted = hint orelse {
        try check.reportLiteralContext(node, null);
        return .poison;
    };
    var peeled: u32 = 0;
    while (peeled < type_depth_max) : (peeled += 1) {
        switch (comp.pool.keyOf(wanted)) {
            .optional => |child| wanted = child,
            .error_union => |child| wanted = child,
            else => break,
        }
    }
    if (wanted == .poison) return .poison;

    const instance = switch (comp.pool.keyOf(wanted)) {
        .struct_type => |instance| instance,
        else => {
            try check.reportLiteralContext(node, hint);
            return .poison;
        },
    };
    if (check.builder == null) return check.needRuntime(node, "a struct literal");

    try comp.ensureRows(instance);
    const rows = comp.instanceAt(instance).rows;

    // one slot per field, in declaration order
    const builder = check.builder.?;
    const start: u32 = @intCast(builder.operands.items.len);
    defer builder.operands.shrinkRetainingCapacity(start);
    try builder.operands.appendNTimes(comp.gpa, .{ .value = .poison, .initializer = .none }, rows.len);

    var clean = true;
    for (inits) |init_node| {
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
            .help = "every field of the struct must be present; there are no defaults",
        });
        return .poison;
    }
    if (clean == false) return .poison;

    const fields = builder.operands.items[start..];
    const payload = try check.emitExtra(&.{@intCast(fields.len)}, fields);
    const result = try check.emit(.struct_init, wanted, node, .{ .payload = payload });
    return .{ .runtime = .{ .ref = result, .type = wanted } };
}

fn reportLiteralContext(check: *Check, node: Node.Index, hint: ?Pool.Index) Allocator.Error!void {
    if (hint) |wanted| {
        try check.fail(node, .{
            .code = .type_mismatch,
            .message = try check.comp.fmt("expected {s}, and '.{{ }}' only builds a struct", .{
                try check.comp.typeName(wanted),
            }),
            .label = "not a struct here",
        });
        return;
    }
    try check.fail(node, .{
        .code = .no_literal_context,
        .message = "nothing here says which struct this literal is",
        .label = "no type in sight",
        .help = "annotate the binding, or use the literal where a struct type is known",
    });
}

/// A count, then one ref per operand. Written the way `Func.structInitAt` and
/// `Func.callAt` read it back.
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

/// Every call goes through here, direct or generic, inferred or written, and
/// the six primitives. Reads the substituted signature and never a body.
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
    if (check.builder == null) {
        return check.needRuntime(node, "a call");
    }
    return check.checkCallResolved(node, callee, view.args);
}

/// A method declaration waits for its receiver type, so the receiver is walked
/// exactly once.
const Callee = struct {
    kind: Kind,
    /// The `[T, U]` written at the call site, or null when none was. Resolved
    /// where the declaration is known, so the count can be checked first.
    explicit: ?[]const Node.Index,

    const Kind = union(enum) {
        /// A plain function, or one reached through a module.
        direct: Decl.Index,
        /// `Type.f(...)`, whose arguments pass exactly as written.
        static: struct { decl: Decl.Index, owner: Pool.Instance },
        /// `value.f(...)`, where the value is the receiver.
        method: struct { receiver: Node.Index, name_token: Token.Index },
    };
};

/// Without evaluating a receiver or an argument. Null means already reported.
fn resolveCallee(check: *Check, callee_node: Node.Index) Allocator.Error!?Callee {
    switch (check.tree.viewOf(callee_node)) {
        .field_access => |access| return check.resolveCalleeMember(callee_node, access),
        .instance => |instance_view| {
            var callee = switch (check.tree.nodeTag(instance_view.base)) {
                .field_access => try check.resolveCalleeMember(
                    instance_view.base,
                    check.tree.viewOf(instance_view.base).field_access,
                ) orelse return null,
                else => callee: {
                    const value = try check.checkExpr(instance_view.base, null);
                    break :callee try check.calleeOfValue(instance_view.base, value) orelse
                        return null;
                },
            };

            if (instance_view.args.len > type_params_max) {
                try check.fail(callee_node, .{
                    .code = .generic_arguments,
                    .message = try check.comp.fmt(
                        "a call takes at most {d} type arguments",
                        .{type_params_max},
                    ),
                });
                return null;
            }
            callee.explicit = instance_view.args;
            return callee;
        },
        else => {
            const value = try check.checkExpr(callee_node, null);
            return check.calleeOfValue(callee_node, value);
        },
    }
}

/// A module or type function when the chain is pure names, and a method with
/// the base as receiver otherwise. The receiver is left unevaluated, because
/// checking emits and it must emit once.
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
            .poison => return null,
            .module_ref => |target| {
                const member = try check.moduleMember(target, callee_node, access.name_token) orelse
                    return null;
                const value = try check.declAsValue(member, callee_node);
                return check.calleeOfValue(callee_node, value);
            },
            .builtin_ref => {
                try check.failBuiltinMisuse(callee_node);
                return null;
            },
            .type_ref => |type_index| {
                switch (comp.pool.keyOf(type_index)) {
                    .struct_type => |owner| {
                        const decl_index = comp.instanceDecl(owner);
                        const member = findMember(comp, decl_index, name_text) orelse {
                            _ = try check.findField(owner, access.name_token);
                            return null;
                        };
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
            .generic_ref => {
                try check.fail(access.lhs, .{
                    .code = .generic_arguments,
                    .message = "this struct is generic; write its arguments before reaching in",
                    .label = "missing type arguments",
                });
                return null;
            },
            .fn_ref => {
                try check.failToken(access.name_token, .{
                    .code = .no_such_member,
                    .message = "a function has no fields; call it first",
                    .label = "'.' on a function",
                });
                return null;
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
            .field_access => current = check.tree.viewOf(current).field_access.lhs,
            .grouped => current = check.tree.viewOf(current).grouped,
            .instance => current = check.tree.viewOf(current).instance.base,
            else => return false,
        }
    }
    return false;
}

fn calleeOfValue(check: *Check, node: Node.Index, value: Value) Allocator.Error!?Callee {
    const comp = check.comp;
    switch (value) {
        .fn_ref => |decl_index| return .{
            .kind = .{ .direct = decl_index },
            .explicit = null,
        },
        .poison => return null,
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
        .type_ref, .generic_ref => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = "a type is not callable; there are no conversions to call",
                .label = "a type",
            });
            return null;
        },
        .module_ref => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = "a module is not callable; name a function inside it",
                .label = "a module",
            });
            return null;
        },
        .builtin_ref => {
            try check.failBuiltinMisuse(node);
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

            const struct_type = peelOnePointer(comp, place.type);
            switch (comp.pool.keyOf(struct_type)) {
                .struct_type => |owner| {
                    const owner_decl = comp.instanceDecl(owner);
                    const name_text = check.tree.tokenSlice(method.name_token);
                    const member = findMember(comp, owner_decl, name_text) orelse {
                        _ = try check.findField(owner, method.name_token);
                        return .poison;
                    };
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

    // the owner's arguments move under instantiation, so copy them out
    var full_args: [type_params_max * 2]Pool.Index = undefined;
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

    // a receiver consumes the first parameter, and arity messages exclude it
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
            .value = .{ .runtime = .{ .ref = receiver, .type = self_type } },
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

    if (decl.builtin()) |bound| {
        // for `Type.f(x)` the first argument is the receiver, and the name rule
        // judges that expression
        const self_node = receiver_node orelse if (args.len > 0) args[0] else null;
        return check.emitBuiltin(node, .{
            .bound = bound,
            .receiver_node = self_node,
        }, builder.operands.items[start..], return_type);
    }

    // on its own `Builder`, so the operands staged here cannot move
    try comp.ensure(.of(.body, instance), check.origin(node));

    const operands = builder.operands.items[start..];
    const target = IR.Callee.fromInstance(instance);
    const payload = try check.emitExtra(&.{
        @intFromEnum(target),
        @intCast(operands.len),
    }, operands);

    const result = try check.emit(.call, return_type, node, .{ .payload = payload });
    return .{ .runtime = .{ .ref = result, .type = return_type } };
}

fn plural(count: u32) []const u8 {
    return if (count == 1) "" else "s";
}

fn peelOnePointer(comp: *const Compilation, type_index: Pool.Index) Pool.Index {
    return switch (comp.pool.keyOf(type_index)) {
        .pointer => |pointer| pointer.child,
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

    // `&place` lives only here, as an argument, addressing the place directly
    if (check.tree.nodeTag(argument) == .unary) {
        const unary = check.tree.viewOf(argument).unary;
        if (unary.op == .address_of) {
            const place = try check.checkPlace(unary.operand) orelse return .poison;
            const wanted_mutable = switch (check.comp.pool.keyOf(row_type)) {
                .pointer => |pointer| pointer.mutable,
                else => false,
            };
            if (wanted_mutable and place.mutable == false) {
                try check.reportImmutable(argument, place);
                return .poison;
            }
            const addressed = try check.placeAddress(unary.operand, place) orelse return .poison;
            const pointer_type = try check.pointerTo(addressed.type, addressed.mutable);
            const value: Value = .{ .runtime = .{ .ref = addressed.ref, .type = pointer_type } };
            return check.coerce(value, row_type, argument);
        }
    }

    const value = try check.checkExpr(argument, row_type);
    return check.coerce(value, row_type, argument);
}

/// Omitted bracket arguments, pinned by declared parameter types. A pin is
/// `value: T` directly or one pointer deep, all or nothing, and refused for a
/// bare number with no type to read.
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

    // arguments are checked in source order, so evaluation order survives
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
                .pointer => |pointer| found = pointer.child,
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

/// The first parameter declared as exactly the named type parameter, or a
/// pointer to it. Read off the tree, before anything resolves.
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

/// As the first argument, in whichever form the declaration asked for. A copy,
/// a read only pointer, or `*var`.
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
        .pointer => |wanted| {
            // the receiver may already be the pointer, or may need its address
            if (place.type == self_type) {
                return try check.placeValue(receiver_node, place);
            }
            const place_key = comp.pool.keyOf(place.type);
            if (place_key == .pointer and place_key.pointer.child == wanted.child) {
                if (wanted.mutable and place_key.pointer.mutable == false) {
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
                return try check.placeValue(receiver_node, place);
            }
            if (place.type == wanted.child) {
                if (wanted.mutable and place.mutable == false) {
                    try check.reportReceiverImmutable(receiver_node, place, fn_name);
                    return null;
                }
                const addressed = try check.placeAddress(receiver_node, place) orelse return null;
                return addressed.ref;
            }
            return check.reportReceiverMismatch(receiver_node, place.type, self_type, fn_name);
        },
        else => {
            // `self: T` takes a copy
            if (place.type == self_type) {
                return try check.placeValue(receiver_node, place);
            }
            const place_key = comp.pool.keyOf(place.type);
            if (place_key == .pointer and place_key.pointer.child == self_type) {
                // through one pointer, the way field access does
                const pointer = try check.placeValue(receiver_node, place);
                return try check.emitOne(.load, self_type, receiver_node, pointer);
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
        .capture_bound => "names what a capture held",
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

const BuiltinCall = struct {
    bound: Compilation.Builtin,
    /// As written, for the rules that judge shape.
    receiver_node: ?Node.Index,
};

/// A bound primitive becomes its instruction, and the rules attached to the
/// primitives live here.
fn emitBuiltin(
    check: *Check,
    node: Node.Index,
    call: BuiltinCall,
    operands: []const Builder.Operand,
    return_type: Pool.Index,
) Allocator.Error!Value {
    switch (call.bound) {
        .arena_init => {
            assert(operands.len == 0);
            const result = try check.emit(.arena_init, return_type, node, .{ .none = {} });
            return .{ .runtime = .{ .ref = result, .type = return_type } };
        },
        .arena_child => {
            assert(operands.len == 1);
            const result = try check.emitOne(.arena_child, return_type, node, refOf(operands[0].value));
            return .{ .runtime = .{ .ref = result, .type = return_type } };
        },
        .arena_create => {
            assert(operands.len == 1);
            const result = try check.emitOne(.arena_create, return_type, node, refOf(operands[0].value));
            return .{ .runtime = .{ .ref = result, .type = return_type } };
        },
        .arena_copy => {
            assert(operands.len == 2);
            const result = try check.emit(.arena_copy, return_type, node, .{
                .bin = .{ .lhs = refOf(operands[0].value), .rhs = refOf(operands[1].value) },
            });
            return .{ .runtime = .{ .ref = result, .type = return_type } };
        },
        .arena_reset, .arena_destroy => {
            assert(operands.len == 1);
            if (try check.checkReleaseName(node, call) == false) return .poison;
            if (call.bound == .arena_destroy) try check.checkDestroyInDefer(node);
            const tag: IR.Inst.Tag = if (call.bound == .arena_reset)
                .arena_reset
            else
                .arena_destroy;
            const result = try check.emitOne(tag, .nothing_type, node, refOf(operands[0].value));
            return .{ .runtime = .{ .ref = result, .type = .nothing_type } };
        },
    }
}

/// `reset` and `destroy` demand a name, judged on the call site expression
/// before any load flattens it.
fn checkReleaseName(check: *Check, node: Node.Index, call: BuiltinCall) Allocator.Error!bool {
    const receiver_node = call.receiver_node orelse node;

    if (check.tree.nodeTag(receiver_node) == .ident) {
        const text = check.tree.tokenSlice(check.tree.nodeMainToken(receiver_node));
        if (check.findLocal(text)) |local| {
            if (check.typeIsRegion(local.type)) return true;
        }
    }

    const verb: []const u8 = if (call.bound == .arena_reset) "reset" else "destroy";
    try check.fail(receiver_node, .{
        .code = .release_needs_name,
        .message = try check.comp.fmt(
            "'{s}' needs the arena's name, and this is a path to one",
            .{verb},
        ),
        .label = "not a name",
        .help = "every value in the arena dies at this instant, and only the function " ++
            "that created the arena can see them; release it there, by name",
    });
    return false;
}

/// A `destroy` in a `defer` fires exactly where the scope was ending anyway.
fn checkDestroyInDefer(check: *Check, node: Node.Index) Allocator.Error!void {
    if (check.builder.?.in_defer == false) return;
    try check.fail(node, .{
        .code = .redundant_destroy,
        .message = "an arena dies at the end of its scope already",
        .label = "'defer' fires at scope exit, when this happens anyway",
        .help = "delete this line; 'destroy' exists to end an arena earlier than its scope",
    });
}

/// A location a chain of names reached. An `address` can be stored through when
/// mutable. A `value` never had an address, and is spilled to one only when
/// something needs to point at it.
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
        capture_bound,
        /// The read-only pointer type the chain crossed, for the message.
        const_pointer: Pool.Index,
        temporary,
    };
};

/// An expression as a location. Null means reported, or downstream of one, and
/// the caller gives up quietly.
fn checkPlace(check: *Check, node: Node.Index) Allocator.Error!?Place {
    switch (check.tree.viewOf(node)) {
        .ident => {
            const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));
            if (std.mem.eql(u8, text, "_")) {
                try check.fail(node, .{
                    .code = .discard_reserved,
                    .message = "'_' is not a place; it only discards a whole value",
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
                    .let_value, .param, .capture => .{
                        .kind = .value,
                        .ref = @enumFromInt(local.payload),
                        .type = local.type,
                        .mutable = false,
                        .reason = switch (local.kind) {
                            .let_value => .let_bound,
                            .param => .param_bound,
                            .capture => .capture_bound,
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
        .grouped => |inner| return check.checkPlace(inner),
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
        .poison => return null,
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

/// One field step. Crossing a pointer resets mutability to the pointer's own,
/// which is the whole rule.
fn placeField(
    check: *Check,
    node: Node.Index,
    base: Place,
    name_token: Token.Index,
) Allocator.Error!?Place {
    const comp = check.comp;
    switch (comp.pool.keyOf(base.type)) {
        .struct_type => |instance| {
            const row = try check.findField(instance, name_token) orelse return null;
            const row_type = comp.rowAt(row).type;

            const addressed = try check.placeAddress(node, base) orelse return null;
            const field_pointer = try check.pointerTo(row_type, addressed.mutable);
            const place = try check.emit(.field_ptr, field_pointer, node, .{
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
        .pointer => |pointer| {
            switch (comp.pool.keyOf(pointer.child)) {
                .struct_type => |instance| {
                    const row = try check.findField(instance, name_token) orelse return null;
                    const row_type = comp.rowAt(row).type;

                    const through = try check.placeValue(node, base);
                    const field_pointer = try check.pointerTo(row_type, pointer.mutable);
                    const place = try check.emit(.field_ptr, field_pointer, node, .{
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
        .optional => {
            try check.fail(node, .{
                .code = .optional_not_unwrapped,
                .message = try comp.fmt("this is {s}; reach inside it first", .{
                    try comp.typeName(base.type),
                }),
                .label = "may be null",
                .help = "'if x |v| { }' and 'x orelse ...' unwrap an optional",
            });
            return null;
        },
        .error_union => {
            try check.fail(node, .{
                .code = .not_error_union,
                .message = try comp.fmt("this is {s}; it can still fail", .{
                    try comp.typeName(base.type),
                }),
                .label = "handle the error first",
                .help = "'try' passes the error up, 'catch' handles it here",
            });
            return null;
        },
        else => {
            const text = check.tree.tokenSlice(name_token);
            try check.reportNoField(node, base.type, text);
            return null;
        },
    }
}

/// Loading when the place is an address.
fn placeValue(check: *Check, node: Node.Index, place: Place) Allocator.Error!Ref {
    return switch (place.kind) {
        .value => place.ref,
        .address => try check.emitOne(.load, place.type, node, place.ref),
    };
}

/// Spilling a value to a temporary when it never had an address. The copy is
/// unobservable, because only immutable values are spilled.
fn placeAddress(check: *Check, node: Node.Index, place: Place) Allocator.Error!?Place {
    if (place.kind == .address) return place;
    if (place.type == .poison) return null;

    const slot = try check.emitSlot(node, .empty, place.type);
    try check.emitStore(node, slot, place.ref);
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
        .capture_bound => .{
            .code = .not_assignable,
            .message = try comp.fmt("'{s}' names what the capture held; it cannot change", .{
                place.root_name,
            }),
            .label = "immutable",
            .help = "copy it into a 'var' to work on it",
        },
        .const_pointer => |crossed| report: {
            const child = comp.pool.keyOf(crossed).pointer.child;
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
            .message = "this value has no home; there is nowhere to write",
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
        .poison => .poison,
        .type_ref, .generic_ref, .fn_ref, .module_ref, .builtin_ref => .poison,
    };
}

/// Anything that is not a value becomes poison, carried on silently.
fn refOf(value: Value) Ref {
    return switch (value) {
        .constant => |constant| .fromConstant(constant),
        .runtime => |runtime| runtime.ref,
        .type_ref, .generic_ref, .fn_ref, .module_ref, .builtin_ref, .poison => {
            return .fromConstant(.poison);
        },
    };
}

/// Constants are checked by value, `*var T` serves as `*T`, and wrapping into
/// an optional or an error union is the only code this adds.
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
        .constant => |constant| return check.meetOrWrap(constant, wanted, node),
        .runtime => |runtime| {
            if (runtime.type == wanted) return value;
            if (runtime.type == .poison) return .poison;

            const have = comp.pool.keyOf(runtime.type);
            const want = comp.pool.keyOf(wanted);

            // the one subtyping edge
            if (have == .pointer and want == .pointer) {
                const compatible = have.pointer.child == want.pointer.child and
                    have.pointer.mutable and want.pointer.mutable == false;
                if (compatible) {
                    return .{ .runtime = .{ .ref = runtime.ref, .type = wanted } };
                }
                if (have.pointer.child == want.pointer.child) {
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

            if (want == .optional) {
                const inner = try check.coerceQuiet(value, want.optional) orelse {
                    return check.reportMismatch(node, value, wanted);
                };
                const wrapped = try check.emitOne(.wrap_optional, wanted, node, refOf(inner));
                return .{ .runtime = .{ .ref = wrapped, .type = wanted } };
            }
            if (want == .error_union) {
                if (runtime.type == .error_type) {
                    const wrapped = try check.emitOne(.wrap_err, wanted, node, runtime.ref);
                    return .{ .runtime = .{ .ref = wrapped, .type = wanted } };
                }
                const inner = try check.coerceQuiet(value, want.error_union) orelse {
                    return check.reportMismatch(node, value, wanted);
                };
                const wrapped = try check.emitOne(.wrap_ok, wanted, node, refOf(inner));
                return .{ .runtime = .{ .ref = wrapped, .type = wanted } };
            }

            return check.reportMismatch(node, value, wanted);
        },
        else => {
            try check.reportNotValue(node, value);
            return .poison;
        },
    }
}

/// `coerce` without the report, for an inner step of a wrap.
fn coerceQuiet(check: *Check, value: Value, wanted: Pool.Index) Allocator.Error!?Value {
    const comp = check.comp;
    switch (value) {
        .constant => |constant| {
            const met = try comp.pool.meet(comp.gpa, constant, wanted);
            switch (met) {
                .value => |final| return .{ .constant = final },
                .does_not_fit, .wrong_kind => return null,
            }
        },
        .runtime => |runtime| {
            if (runtime.type == wanted) return value;
            const have = comp.pool.keyOf(runtime.type);
            const want = comp.pool.keyOf(wanted);
            if (have == .pointer and want == .pointer) {
                const compatible = have.pointer.child == want.pointer.child and
                    have.pointer.mutable and want.pointer.mutable == false;
                if (compatible) return .{ .runtime = .{ .ref = runtime.ref, .type = wanted } };
            }
            return null;
        },
        else => return null,
    }
}

/// The type may be an optional or an error union, so this can produce a wrap
/// and a runtime value.
fn meetOrWrap(
    check: *Check,
    constant: Pool.Index,
    wanted: Pool.Index,
    node: Node.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    if (constant == .poison) return .poison;
    if (wanted == .poison) return .poison;

    const met = try comp.pool.meet(comp.gpa, constant, wanted);
    switch (met) {
        .value => |final| return .{ .constant = final },
        .does_not_fit => {
            try check.reportDoesNotFit(node, constant, wanted);
            return .poison;
        },
        .wrong_kind => {},
    }

    switch (comp.pool.keyOf(wanted)) {
        .optional => |child| {
            const inner = try check.meetOrWrap(constant, child, node);
            if (inner == .poison) return .poison;
            const builder_ok = check.builder != null;
            if (builder_ok == false) return check.needRuntime(node, "wrapping an optional");
            const wrapped = try check.emitOne(.wrap_optional, wanted, node, refOf(inner));
            return .{ .runtime = .{ .ref = wrapped, .type = wanted } };
        },
        .error_union => |child| {
            const builder_ok = check.builder != null;
            if (builder_ok == false) return check.needRuntime(node, "wrapping an error union");
            if (comp.pool.keyOf(constant) == .error_value) {
                const raised: Ref = .fromConstant(constant);
                const wrapped = try check.emitOne(.wrap_err, wanted, node, raised);
                return .{ .runtime = .{ .ref = wrapped, .type = wanted } };
            }
            const inner = try check.meetOrWrap(constant, child, node);
            if (inner == .poison) return .poison;
            const wrapped = try check.emitOne(.wrap_ok, wanted, node, refOf(inner));
            return .{ .runtime = .{ .ref = wrapped, .type = wanted } };
        },
        else => {
            return check.reportMismatch(node, .{ .constant = constant }, wanted);
        },
    }
}

/// The result must stay a constant, for a top level binding.
fn meetConstant(
    check: *Check,
    constant: Pool.Index,
    wanted: Pool.Index,
    node: Node.Index,
) Allocator.Error!Pool.Index {
    const comp = check.comp;
    if (constant == .poison) return .poison;
    if (wanted == .poison) return .poison;

    const met = try comp.pool.meet(comp.gpa, constant, wanted);
    switch (met) {
        .value => |final| return final,
        .does_not_fit => {
            try check.reportDoesNotFit(node, constant, wanted);
            return .poison;
        },
        .wrong_kind => {
            switch (comp.pool.keyOf(wanted)) {
                .optional, .error_union => {
                    try check.fail(node, .{
                        .code = .not_constant,
                        .message = try comp.fmt(
                            "this value only becomes {s} at run time, and a top-level " ++
                                "binding is a constant",
                            .{try comp.typeName(wanted)},
                        ),
                        .label = "not a constant",
                        .help = "move the binding into a function, or drop the annotation",
                    });
                },
                else => _ = try check.reportMismatch(node, .{ .constant = constant }, wanted),
            }
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
        .help = "a constant takes any type its value fits; this value does not fit this one",
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
    const found_name = switch (value) {
        .constant => |constant| switch (comp.pool.keyOf(constant)) {
            .simple => |simple| if (simple == .null) "null" else try comp.typeName(found),
            else => try comp.typeName(found),
        },
        else => try comp.typeName(found),
    };
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
        .constant, .runtime, .poison => return true,
        else => {
            try check.reportNotValue(node, value);
            return false;
        },
    }
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
        .type_ref, .generic_ref => .{
            .code = .type_as_value,
            .message = "types are not values",
            .label = "a type, where a value belongs",
            .help = "a type appears in type positions, and as the base of a '.' access",
        },
        .fn_ref => .{
            .code = .not_a_function,
            .message = "a function is not a value; call it",
            .label = "missing the call",
            .help = "there are no function values in the language",
        },
        .module_ref => .{
            .code = .type_as_value,
            .message = "a module is not a value",
            .label = "a module, where a value belongs",
        },
        .builtin_ref => return check.failBuiltinMisuse(node),
        .constant, .runtime, .poison => unreachable,
    };
    try check.fail(node, report);
}

fn failBuiltinMisuse(check: *Check, node: Node.Index) Allocator.Error!void {
    try check.fail(node, .{
        .code = .builtin_outside_std,
        .message = "the primitives are not callable, only bindable",
        .label = "not a value",
        .help = "a whole function body of the form '= builtin.name' binds one",
    });
}

fn reportBadOperand(
    check: *Check,
    op_token: Token.Index,
    op: AST.BinaryOp,
    operand_type: Pool.Index,
) Allocator.Error!void {
    try check.failToken(op_token, .{
        .code = .bad_operand,
        .message = try check.comp.fmt("'{t}' cannot be applied to {s}", .{
            op,
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

/// Among locals, type parameters, this file's declarations, and the universals.
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
    for (Pool.universal_names) |name| considerName(name, text, &best, &best_distance);

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

    // reachability from the entry, over the terminators
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

    // only blocks are renumbered. instructions keep the positions they were
    // built at, so every ref stays valid and a dropped block is never reached
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
