//! Type checking: the type grammar, the constant sublanguage, and the
//! diagnostics shared with `Lower`, which walks function bodies.

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
/// The names a body has bound, innermost last. A constant has none, and
/// `Lower` drives this while it walks.
locals: std.ArrayList(Local),
/// Field types skip the size demand, because their struct gets its own walk.
demand_sizes: bool,

const Check = @This();

pub const type_params_max = 16;
pub const call_args_max = 255;
pub const type_depth_max = AST.nest_max;

pub const Binding = struct { name: Pool.String, type: Pool.Index };

/// A name a body bound, and what stands behind it.
pub const Local = struct {
    name: Pool.String,
    node: Node.Index,
    kind: Kind,
    /// A ref, or a pool constant for `let_constant`.
    payload: u32,
    /// A `var_slot` ref is a pointer to this.
    type: Pool.Index,

    pub const Kind = enum(u8) { let_constant, let_value, var_slot, param, capture };
};

/// What an expression turned out to be. A `_ref` is not a value, and is legal
/// only where its comment says. The constant walk never reaches `runtime` or
/// `never`, because both need a body.
pub const Value = union(enum) {
    constant: Pool.Index,
    runtime: Runtime,
    /// No value, no diagnostic owed. `poison` is the same after one.
    never,
    poison,
    /// `Point` in `Point.zero()`.
    type_ref: Pool.Index,
    /// `Box` in `Box[i64]`, awaiting arguments.
    generic_ref: Decl.Index,
    /// `helper` in `helper(1)`.
    fn_ref: Decl.Index,
    /// `std` in `std.mem`.
    module_ref: Module.Index,
    /// `builtin` in `= builtin.arena_init`.
    builtin_ref,

    pub const Runtime = struct { ref: Ref, type: Pool.Index };

    /// A void result. Callers read the type, never the ref.
    pub const nothing: Value = .{ .runtime = .{ .ref = .fromConstant(.poison), .type = .nothing_type } };
};

// entry points, one per constant unit kind `ensure` dispatches

pub fn typeAlias(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    var check = init(comp, decl_index, &.{});
    defer check.deinit();
    const view = check.tree.viewOf(check.declNode(decl_index)).type_decl;

    const resolved = try check.resolveWrittenType(view.aliased);
    comp.declPtr(decl_index).result = resolved.int();
    return resolved != .poison;
}

pub fn topLevelLet(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    var check = init(comp, decl_index, &.{});
    defer check.deinit();
    const view = check.tree.viewOf(check.declNode(decl_index)).var_decl;
    assert(view.is_mutable == false);

    const value = try check.constantExpr(view.init_expr);
    const constant = switch (value) {
        .constant => |index| index,
        .poison => Pool.Index.poison,
        .runtime, .never => unreachable,
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
    var check = init(comp, decl_index, bindings);
    defer check.deinit();
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

/// A struct embedding itself by value has no size, which `ensure` reports.
pub fn structSize(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    const decl = comp.declAt(decl_index);
    const from: Compilation.Origin = .{ .module = decl.module, .node = decl.node };
    try comp.ensure(.of(.rows, instance), from);

    const rows = comp.instanceAt(instance).rows;
    for (rows.start..rows.end()) |raw| {
        // by index, because the walk can grow the rows table
        const row = comp.rowAt(@intCast(raw));
        try sizeWalkType(comp, row.type, .{ .module = decl.module, .node = row.node }, 0);
    }
    return true;
}

/// The types a value embeds directly. A pointer breaks the chain.
fn sizeWalkType(
    comp: *Compilation,
    type_index: Pool.Index,
    from: Compilation.Origin,
    depth: u32,
) Allocator.Error!void {
    if (depth >= type_depth_max) return;
    switch (comp.pool.keyOf(type_index)) {
        .struct_type => |embedded| try comp.ensure(.of(.size, embedded), from),
        .optional_type, .error_union_type => |child| try sizeWalkType(comp, child, from, depth + 1),
        .simple_type, .simple_value, .pointer_type => {},
        .int, .float, .error_value, .optional_null => unreachable,
    }
}

pub fn fnSignature(comp: *Compilation, instance: Pool.Instance) Allocator.Error!bool {
    const decl_index = comp.instanceDecl(instance);
    var buffer: [type_params_max]Binding = undefined;
    const bindings = try bindTypeParams(comp, instance, &buffer) orelse return false;
    var check = init(comp, decl_index, bindings);
    defer check.deinit();

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
                    .help = "make a child inside for scratch local to this call, or store the arena " ++
                        "in the collection it fills for scratch shared across calls",
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
pub fn bindTypeParams(
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

pub fn init(comp: *Compilation, decl_index: Decl.Index, bindings: []const Binding) Check {
    const decl = comp.declAt(decl_index);
    const module = comp.moduleAt(decl.module);
    assert(module.failed == false);
    return .{
        .comp = comp,
        .module_index = decl.module,
        .module = module,
        .tree = &module.tree,
        .bindings = bindings,
        .locals = .empty,
        .demand_sizes = true,
    };
}

pub fn deinit(check: *Check) void {
    check.locals.deinit(check.comp.gpa);
    check.* = undefined;
}

pub fn declNode(check: *const Check, decl_index: Decl.Index) Node.Index {
    const decl = check.comp.declAt(decl_index);
    assert(decl.module == check.module_index);
    return decl.node;
}

// type expressions, where the type grammar meets the pool

/// A written type promises storage, so what it embeds must have a size.
pub fn resolveWrittenType(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const resolved = try check.resolveType(node);
    if (check.demand_sizes and resolved != .poison) {
        try sizeWalkType(check.comp, resolved, check.origin(node), 0);
    }
    return resolved;
}

pub fn resolveType(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const comp = check.comp;

    switch (check.tree.viewOf(node)) {
        .ident => return check.resolveTypeName(node),
        .field_access => |access| {
            const base = try check.resolveTypeBase(access.lhs);
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
                .pointer_type = .{ .child = child, .mutable = pointer.is_mutable },
            });
        },
        .optional_type => |child_node| {
            const child = try check.resolveType(child_node);
            if (child == .poison) return .poison;
            if (comp.pool.keyOf(child) == .error_union_type) {
                try check.fail(node, .{
                    .code = .not_error_union,
                    .message = "an optional cannot hold an error union",
                    .label = "the '!' belongs outside",
                    .help = "write '!?T' for a value that may fail, and may succeed with nothing",
                });
                return .poison;
            }
            return comp.pool.intern(comp.gpa, .{ .optional_type = child });
        },
        .error_union_type => |child_node| {
            const child = try check.resolveType(child_node);
            if (child == .poison) return .poison;
            // by the resolved type, so an alias cannot smuggle a '!' in
            if (comp.pool.keyOf(child) == .error_union_type) {
                try check.fail(node, .{
                    .code = .not_error_union,
                    .message = "an error union cannot hold another error union",
                    .label = "one '!' is enough",
                    .help = "there is one universal error set, so '!T' already covers every error",
                });
                return .poison;
            }
            return comp.pool.intern(comp.gpa, .{ .error_union_type = child });
        },
        .err => return .poison,
        // the parser builds only type nodes in type positions
        else => unreachable,
    }
}

/// The left of a dotted type, which is a path of names. A local shadows
/// nothing here, so it is refused where it stands rather than resolved.
fn resolveTypeBase(check: *Check, node: Node.Index) Allocator.Error!Value {
    if (check.tree.nodeTag(node) == .ident) {
        const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));
        if (check.findLocal(text) != null) {
            try check.fail(node, .{
                .code = .not_a_type,
                .message = try check.comp.fmt("'{s}' is a value, and only a module reaches " ++
                    "a type with '.'", .{text}),
                .label = "not a module",
            });
            return .poison;
        }
    }
    return check.constantExpr(node);
}

pub fn pointerTo(check: *Check, child: Pool.Index, mutable: bool) Allocator.Error!Pool.Index {
    const comp = check.comp;
    return comp.pool.intern(comp.gpa, .{ .pointer_type = .{ .child = child, .mutable = mutable } });
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
        .let, .error_decl, .fn_decl => {
            const what = switch (decl.kind) {
                .let => "a value",
                .error_decl => "an error",
                else => "a function",
            };
            try check.fail(node, .{
                .code = .not_a_type,
                .message = try comp.fmt("'{s}' is {s}, not a type", .{ name, what }),
                .label = "not a type",
            });
            return .poison;
        },
    }
}

pub fn resolveTypeInstance(check: *Check, node: Node.Index) Allocator.Error!Pool.Index {
    const comp = check.comp;
    const view = check.tree.viewOf(node).instance;

    const base = try check.resolveTypeBase(view.base);
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
pub fn typeIsRegion(check: *const Check, type_index: Pool.Index) bool {
    const comp = check.comp;
    switch (comp.pool.keyOf(type_index)) {
        .struct_type => |instance| {
            const decl_index = comp.instanceDecl(instance);
            return comp.declAt(decl_index).is_region;
        },
        else => return false,
    }
}

// the constant sublanguage: literals, names of constants, operators, and
// parentheses. Nothing here builds an instruction, because there is no body
// to build into.

fn constantExpr(check: *Check, node: Node.Index) Allocator.Error!Value {
    switch (check.tree.viewOf(node)) {
        .ident => {
            const text = check.tree.tokenSlice(check.tree.nodeMainToken(node));
            return check.namedValue(node, text);
        },
        .number_literal => return check.number(node),
        .bool_literal => |view| {
            return .{ .constant = if (view.value) .true_value else .false_value };
        },
        .null_literal => return .{ .constant = .null_value },
        .grouped => |inner| return check.constantExpr(inner),
        .binary => |view| return check.constantBinary(view),
        .unary => |view| return check.constantUnary(node, view),
        .field_access => |view| return check.constantField(node, view),
        .instance => |view| {
            const base = try check.constantExpr(view.base);
            return check.instanceOf(node, base);
        },
        .err => return .poison,
        else => return check.reportNotConstant(node),
    }
}

fn constantBinary(check: *Check, view: AST.View.Binary) Allocator.Error!Value {
    if (view.op == .bool_and or view.op == .bool_or) {
        return check.constantShortCircuit(view);
    }

    const lhs = try check.constantExpr(view.lhs);
    const rhs = try check.constantExpr(view.rhs);
    if (lhs == .poison or rhs == .poison) return .poison;
    if (try check.valueOnly(view.lhs, lhs) == false) return .poison;
    if (try check.valueOnly(view.rhs, rhs) == false) return .poison;

    assert(lhs == .constant and rhs == .constant);
    return check.foldBinary(view, lhs.constant, rhs.constant);
}

/// The left may decide it, and the right is checked either way.
fn constantShortCircuit(check: *Check, view: AST.View.Binary) Allocator.Error!Value {
    const lhs = try check.constantExpr(view.lhs);
    const left = try check.meetValue(lhs, .bool_type, view.lhs);
    if (left == .poison) {
        _ = try check.constantExpr(view.rhs);
        return .poison;
    }

    const decides = left.constant ==
        (if (view.op == .bool_and) Pool.Index.false_value else Pool.Index.true_value);
    if (decides) {
        _ = try check.constantExpr(view.rhs);
        return left;
    }

    const rhs = try check.constantExpr(view.rhs);
    return check.meetValue(rhs, .bool_type, view.rhs);
}

fn constantUnary(check: *Check, node: Node.Index, view: AST.View.Unary) Allocator.Error!Value {
    const comp = check.comp;
    switch (view.op) {
        .address_of => return check.reportAddressPosition(node),
        .negate => {
            const operand = try check.constantExpr(view.operand);
            if (operand == .poison) return .poison;
            if (try check.valueOnly(view.operand, operand) == false) return .poison;

            assert(operand == .constant);
            const folded = try comp.pool.foldNegate(comp.gpa, operand.constant);
            return check.foldUnaryResult(view.op_token, folded);
        },
        .bool_not => {
            const operand = try check.constantExpr(view.operand);
            if (operand == .poison) return .poison;
            if (try check.valueOnly(view.operand, operand) == false) return .poison;

            assert(operand == .constant);
            return check.foldUnaryResult(view.op_token, comp.pool.foldNot(operand.constant));
        },
    }
}

/// Only a namespace reaches through '.' without a body, because reading a
/// field of a value is an instruction.
fn constantField(
    check: *Check,
    node: Node.Index,
    view: AST.View.FieldAccess,
) Allocator.Error!Value {
    const comp = check.comp;
    const base = try check.constantExpr(view.lhs);

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
        .constant => {
            const found = check.typeOf(base);
            switch (comp.pool.keyOf(found)) {
                .optional_type, .error_union_type => try check.reportUnopened(node, found),
                else => try check.reportNoField(
                    node,
                    found,
                    check.tree.tokenSlice(view.name_token),
                ),
            }
            return .poison;
        },
        .runtime, .never => unreachable,
        else => return check.reportNamespaceField(node, base, view.name_token),
    }
}

fn reportNotConstant(check: *Check, node: Node.Index) Allocator.Error!Value {
    const what: []const u8 = switch (check.tree.nodeTag(node)) {
        .if_expr => "an 'if'",
        .block => "a block",
        .return_expr => "'return'",
        .break_expr => "'break'",
        .continue_expr => "'continue'",
        .orelse_expr => "'orelse'",
        .catch_expr => "'catch'",
        .try_expr => "'try'",
        .call => "a call",
        .struct_literal => "a struct literal",
        // the parser keeps statements out of expression position
        else => unreachable,
    };
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

// names and members, shared by both walks

/// A name that is not a local: a type parameter, a universal, or a
/// declaration of this file.
pub fn namedValue(check: *Check, node: Node.Index, text: []const u8) Allocator.Error!Value {
    const comp = check.comp;

    if (std.mem.eql(u8, text, "_")) {
        try check.fail(node, .{
            .code = .discard_reserved,
            .message = "'_' has no value, and only discards one",
            .label = "not a value",
        });
        return .poison;
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

pub fn declAsValue(check: *Check, decl_index: Decl.Index, node: Node.Index) Allocator.Error!Value {
    const comp = check.comp;
    const decl = comp.declAt(decl_index);
    switch (decl.kind) {
        .let => {
            try comp.ensure(.forDecl(decl_index), check.origin(node));
            if (comp.declAt(decl_index).state != .done) return .poison;
            return .{ .constant = @enumFromInt(comp.declAt(decl_index).result) };
        },
        .error_decl => return .{
            .constant = try comp.pool.intern(comp.gpa, .{ .error_value = decl_index }),
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

/// A generic struct with its type arguments. The base is walked by the caller,
/// because only a body can walk one that reads a local.
pub fn instanceOf(check: *Check, node: Node.Index, base: Value) Allocator.Error!Value {
    switch (base) {
        .generic_ref => {
            const resolved = try check.resolveTypeInstance(node);
            if (resolved == .poison) return .poison;
            return .{ .type_ref = resolved };
        },
        .fn_ref => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = "a function with its type arguments is still not a value, so call it",
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

pub fn moduleMember(
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

/// With a suggestion when the name misses.
pub fn findField(
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
pub fn fieldRow(
    check: *Check,
    instance: Pool.Instance,
    name_text: []const u8,
) Allocator.Error!?u32 {
    const comp = check.comp;
    try comp.ensureRows(instance);

    const rows = comp.instanceAt(instance).rows;
    for (rows.start..rows.end()) |raw| {
        const row_name = comp.pool.stringText(comp.rowAt(@intCast(raw)).name);
        if (std.mem.eql(u8, row_name, name_text)) return @intCast(raw);
    }
    return null;
}

pub fn findMember(
    comp: *const Compilation,
    decl_index: Decl.Index,
    name_text: []const u8,
) ?Decl.Index {
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

// locals, which only a body binds

/// The innermost binding of the name, and null outside a body.
pub fn findLocal(check: *const Check, name: []const u8) ?Local {
    var index = check.locals.items.len;
    while (index > 0) {
        index -= 1;
        const local = check.locals.items[index];
        if (std.mem.eql(u8, check.comp.pool.stringText(local.name), name)) return local;
    }
    return null;
}

pub fn declareLocal(check: *Check, local: Local, node: Node.Index) Allocator.Error!void {
    const comp = check.comp;
    const text = comp.pool.stringText(local.name);

    // locals may not shadow anything visible
    const clash: ?Compilation.Report = clash: {
        for (check.locals.items) |other| {
            if (other.name == local.name) {
                break :clash .{
                    .code = .shadows,
                    .message = try comp.fmt("'{s}' is already in scope", .{text}),
                    .label = "shadows the outer one",
                    .notes = try comp.notes(&.{
                        comp.noteAt(check.module_index, other.node, "first bound here"),
                    }),
                };
            }
        }
        for (check.bindings) |binding| {
            if (binding.name == local.name) {
                break :clash .{
                    .code = .shadows,
                    .message = try comp.fmt("'{s}' is a type parameter here", .{text}),
                    .label = "shadows it",
                };
            }
        }
        if (Pool.universalType(text) != null) {
            break :clash .{
                .code = .shadows,
                .message = try comp.fmt("'{s}' is the name of a type every file can see", .{
                    text,
                }),
                .label = "shadows it",
            };
        }
        if (check.module.findDecl(local.name)) |decl_index| {
            const decl = comp.declAt(decl_index);
            break :clash .{
                .code = .shadows,
                .message = try comp.fmt("'{s}' is already declared in this file", .{text}),
                .label = "shadows it",
                .notes = try comp.notes(&.{
                    comp.noteAt(check.module_index, decl.node, "declared here"),
                }),
            };
        }
        break :clash null;
    };
    if (clash) |report| try check.fail(node, report);

    try check.locals.append(comp.gpa, local);
}

/// A broken binding poisons its uses silently.
pub fn declarePoisoned(check: *Check, name: Pool.String, node: Node.Index) Allocator.Error!void {
    try check.declareLocal(.{
        .name = name,
        .node = node,
        .kind = .let_constant,
        .payload = Pool.Index.poison.int(),
        .type = .poison,
    }, node);
}

// literals and folding

pub fn number(check: *Check, node: Node.Index) Allocator.Error!Value {
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

/// Every edge is reported at the operator.
pub fn foldBinary(
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
                .help = "nothing converts on its own, so give both sides one type",
            });
            return .poison;
        },
        .bad_operand => |operand_type| {
            try check.reportBadOperand(view.op_token, view.op, operand_type);
            return .poison;
        },
    }
}

pub fn foldUnaryResult(
    check: *Check,
    op_token: Token.Index,
    folded: Pool.Fold,
) Allocator.Error!Value {
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

// meeting a constant with a type

/// The result must stay a constant, which is what a top-level binding is and
/// what a fold needs.
pub fn meetConstant(
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
                .optional_type, .error_union_type => {
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

/// `meetConstant` over a `Value`, for the constant walk.
fn meetValue(
    check: *Check,
    value: Value,
    wanted: Pool.Index,
    node: Node.Index,
) Allocator.Error!Value {
    switch (value) {
        .poison => return .poison,
        .constant => |constant| {
            const met = try check.meetConstant(constant, wanted, node);
            if (met == .poison) return .poison;
            return .{ .constant = met };
        },
        .runtime, .never => unreachable,
        else => {
            try check.reportNotValue(node, value);
            return .poison;
        },
    }
}

// small shared answers

pub fn typeOf(check: *const Check, value: Value) Pool.Index {
    return switch (value) {
        .constant => |constant| check.comp.pool.typeOfValue(constant),
        .runtime => |runtime| runtime.type,
        .poison, .never => .poison,
        .type_ref, .generic_ref, .fn_ref, .module_ref, .builtin_ref => .poison,
    };
}

pub fn runtimeValue(ref: Ref, type_index: Pool.Index) Value {
    return .{ .runtime = .{ .ref = ref, .type = type_index } };
}

/// Anything with no ref of its own becomes poison.
pub fn refOf(value: Value) Ref {
    return switch (value) {
        .constant => |constant| .fromConstant(constant),
        .runtime => |runtime| runtime.ref,
        .never, .poison => .fromConstant(.poison),
        .type_ref, .generic_ref, .fn_ref, .module_ref, .builtin_ref => .fromConstant(.poison),
    };
}

/// Whether a slot can be made of this.
pub fn typeCanHold(check: *const Check, type_index: Pool.Index) bool {
    if (type_index == .nothing_type) return false;
    if (type_index == .untyped_int_type) return false;
    if (type_index == .untyped_float_type) return false;
    return check.comp.pool.isType(type_index);
}

/// A statement wants nothing, the one hint that changes a shape.
pub fn wantsValue(hint: ?Pool.Index) bool {
    const wanted = hint orelse return true;
    return wanted != .nothing_type;
}

pub fn tagIsStatement(tag: Node.Tag) bool {
    return switch (tag) {
        .var_decl, .assign, .while_stmt, .defer_stmt, .err => true,
        else => false,
    };
}

pub fn plural(count: u32) []const u8 {
    return if (count == 1) "" else "s";
}

pub fn peelOnePointer(comp: *const Compilation, type_index: Pool.Index) Pool.Index {
    return switch (comp.pool.keyOf(type_index)) {
        .pointer_type => |pointer| pointer.child,
        else => type_index,
    };
}

pub fn valueOnly(check: *Check, node: Node.Index, value: Value) Allocator.Error!bool {
    switch (value) {
        .constant, .runtime, .poison, .never => return true,
        else => {
            try check.reportNotValue(node, value);
            return false;
        },
    }
}

// diagnostics

pub fn origin(check: *const Check, node: Node.Index) Compilation.Origin {
    return .{ .module = check.module_index, .node = node };
}

pub fn fail(check: *Check, node: Node.Index, report: Compilation.Report) Allocator.Error!void {
    try check.comp.reportNode(check.module_index, node, report);
}

pub fn failToken(
    check: *Check,
    token: Token.Index,
    report: Compilation.Report,
) Allocator.Error!void {
    try check.comp.reportToken(check.module_index, token, report);
}

pub fn reportNotValue(check: *Check, node: Node.Index, value: Value) Allocator.Error!void {
    const report: Compilation.Report = switch (value) {
        .type_ref, .generic_ref => .{
            .code = .type_as_value,
            .message = "types are not values",
            .label = "a type, where a value belongs",
            .help = "a type appears in type positions, and as the base of a '.' access",
        },
        .fn_ref => .{
            .code = .not_a_function,
            .message = "a function is not a value, so call it",
            .label = "missing the call",
            .help = "there are no function values in the language",
        },
        .module_ref => .{
            .code = .type_as_value,
            .message = "a module is not a value",
            .label = "a module, where a value belongs",
        },
        .builtin_ref => return check.failBuiltinMisuse(node),
        // a value that never arrives is never complained about
        .constant, .runtime, .poison, .never => unreachable,
    };
    try check.fail(node, report);
}

/// A '.' onto something that is a namespace, or wanted to be one.
fn reportNamespaceField(
    check: *Check,
    node: Node.Index,
    base: Value,
    name_token: Token.Index,
) Allocator.Error!Value {
    switch (base) {
        .type_ref, .generic_ref => {
            try check.fail(node, .{
                .code = .not_a_function,
                .message = try check.comp.fmt("'{s}' is reached through a value or called, " ++
                    "and cannot be read", .{check.tree.tokenSlice(name_token)}),
                .label = "not a value",
            });
        },
        .fn_ref => {
            try check.fail(node, .{
                .code = .no_such_member,
                .message = "a function has no fields, so call it first",
                .label = "'.' on a function",
            });
        },
        else => unreachable,
    }
    return .poison;
}

pub fn reportAddressPosition(check: *Check, node: Node.Index) Allocator.Error!Value {
    try check.fail(node, .{
        .code = .address_position,
        .message = "'&' can only appear as a call argument",
        .label = "not an argument here",
        .help = "a borrowed address cannot be stored, returned, or named, " ++
            "so it never outlives the call",
    });
    return .poison;
}

pub fn failBuiltinMisuse(check: *Check, node: Node.Index) Allocator.Error!void {
    try check.fail(node, .{
        .code = .builtin_outside_std,
        .message = "the primitives are not callable, only bindable",
        .label = "not a value",
        .help = "a whole function body of the form '= builtin.name' binds one",
    });
}

pub fn reportBadOperand(
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

fn reportBadNumber(check: *Check, node: Node.Index, text: []const u8) Allocator.Error!void {
    try check.fail(node, .{
        .code = .not_a_number,
        .message = try check.comp.fmt("'{s}' is not a number the language knows", .{text}),
        .label = "unreadable",
        .help = "numbers are decimal, hex '0x', octal '0o', or binary '0b', " ++
            "with '.' and 'e' for floats",
    });
}

pub fn reportUndefined(check: *Check, node: Node.Index, text: []const u8) Allocator.Error!void {
    try check.fail(node, .{
        .code = .undefined_name,
        .message = try check.comp.fmt("nothing named '{s}' is in scope here", .{text}),
        .label = "unknown name",
        .help = try check.suggestName(text),
    });
}

/// Among the locals, type parameters, this file's declarations, and the
/// universals.
fn suggestName(check: *Check, text: []const u8) Allocator.Error!?[]const u8 {
    const comp = check.comp;
    var best: ?[]const u8 = null;
    var best_distance: u32 = 3;

    for (check.locals.items) |local| {
        considerName(comp.pool.stringText(local.name), text, &best, &best_distance);
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

fn considerName(candidate: []const u8, text: []const u8, best: *?[]const u8, distance: *u32) void {
    const measured = edit_distance.between(text, candidate);
    if (measured < distance.*) {
        distance.* = measured;
        best.* = candidate;
    }
}

pub fn reportUnopened(check: *Check, node: Node.Index, found: Pool.Index) Allocator.Error!void {
    const comp = check.comp;
    switch (comp.pool.keyOf(found)) {
        .optional_type => try check.fail(node, .{
            .code = .optional_not_unwrapped,
            .message = try comp.fmt("this is {s}, so reach inside it first", .{
                try comp.typeName(found),
            }),
            .label = "may be null",
            .help = "'if x |v| { }' and 'x orelse ...' unwrap an optional",
        }),
        .error_union_type => try check.fail(node, .{
            .code = .not_error_union,
            .message = try comp.fmt("this is {s}, and it can still fail", .{
                try comp.typeName(found),
            }),
            .label = "handle the error first",
            .help = "'try' passes the error up, 'catch' handles it here",
        }),
        else => unreachable,
    }
}

pub fn reportNoField(
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

pub fn reportNotMethod(
    check: *Check,
    name_token: Token.Index,
    found: Pool.Index,
) Allocator.Error!void {
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

pub fn reportLiteralContext(
    check: *Check,
    node: Node.Index,
    hint: ?Pool.Index,
) Allocator.Error!void {
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

/// A constant that has not met a type has no name to print.
pub fn reportUnusedValue(
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

pub fn reportDoesNotFit(
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

pub fn reportMismatch(
    check: *Check,
    node: Node.Index,
    value: Value,
    wanted: Pool.Index,
) Allocator.Error!Value {
    const comp = check.comp;
    const found = check.typeOf(value);
    const found_name = switch (value) {
        .constant => |constant| switch (comp.pool.keyOf(constant)) {
            .simple_value => |simple| if (simple == .null) "null" else try comp.typeName(found),
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
