//! Lowers one function body to `Nir`, typing every value as it goes.
//!
//! Signatures are already resolved, so nothing here reads another body. Local names are
//! resolved here and never reach the checker: an identifier becomes the index of the
//! instruction that produced it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Namespace = @import("Namespace.zig");
const Nir = @import("Nir.zig");
const Sema = @import("Sema.zig");
const Type = @import("Type.zig");

const Lower = @This();
const Token = Ast.TokenIndex;
const Inst = Nir.Inst;
const Mark = Diagnostic.Mark;
const Span = struct { Token, Token };
const Note = Diagnostic.Note;

sema: *Sema,
gpa: Allocator,
pool: *InternPool,
tree: *const Ast,
function: Ast.View.FnDecl,
/// What a `return` is checked against.
returns: Type.Index,
insts: std.ArrayList(Inst) = .empty,
extra: std.ArrayList(u32) = .empty,
names: std.ArrayList(Ast.TokenIndex) = .empty,
/// Innermost last, so a backward scan finds the name that shadows. A block shrinks back
/// to the length it entered with.
locals: std.ArrayList(Local) = .empty,

/// Rebinding a `var` points the name at a new instruction, which is why no storage slot
/// is needed. That holds only while bodies are straight line.
const Local = struct {
    name: []const u8,
    token: Token,
    inst: u32,
    ty: Type.Index,
    is_mutable: bool,
};

pub fn run(sema: *Sema, decl: Namespace.Decl) Allocator.Error!Nir {
    const function = sema.tree.viewOf(decl.node).fn_decl;
    const signature: InternPool.Key.Func = switch (sema.pool.keyOf(decl.ty)) {
        .func => |func| func,
        else => .{ .params = &.{}, .return_type = .poisoned },
    };

    var lower: Lower = .{
        .sema = sema,
        .gpa = sema.gpa,
        .pool = sema.pool,
        .tree = sema.tree,
        .function = function,
        .returns = signature.return_type,
    };
    defer lower.locals.deinit(lower.gpa);
    errdefer {
        lower.insts.deinit(lower.gpa);
        lower.extra.deinit(lower.gpa);
        lower.names.deinit(lower.gpa);
    }

    try lower.bindParams(signature.params);
    try lower.block(function.body);

    return .{
        .insts = try lower.insts.toOwnedSlice(lower.gpa),
        .extra = try lower.extra.toOwnedSlice(lower.gpa),
        .names = try lower.names.toOwnedSlice(lower.gpa),
    };
}

fn bindParams(lower: *Lower, params: []const Type.Index) Allocator.Error!void {
    var at: u32 = 0;
    for (lower.function.params) |node| {
        const param = switch (lower.tree.viewOf(node)) {
            .param => |it| it,
            else => continue,
        };
        if (at >= params.len) break; // a duplicate name the signature dropped
        const inst = try lower.add(.{
            .tag = .arg,
            .token = param.name_token,
            .ty = params[at],
            .lhs = at,
        });
        try lower.declare(param.name_token, inst, params[at], false);
        at += 1;
    }
}

// Building

fn add(lower: *Lower, inst: Inst) Allocator.Error!u32 {
    const at: u32 = @intCast(lower.insts.items.len);
    try lower.insts.append(lower.gpa, inst);
    try lower.names.append(lower.gpa, Nir.no_name);
    return at;
}

fn todo(lower: *Lower, token: Token) Allocator.Error!u32 {
    return lower.add(.{ .tag = .todo, .token = token, .ty = .poisoned });
}

fn report(lower: *Lower, entry: Diagnostic.Entry) Allocator.Error!void {
    try lower.sema.diagnostics.add(entry);
}

/// Reports, and stands in for the value that could not be produced.
fn fail(lower: *Lower, entry: Diagnostic.Entry) Allocator.Error!u32 {
    try lower.report(entry);
    return lower.todo(entry.token);
}

fn typeOf(lower: *const Lower, inst: u32) Type.Index {
    return lower.insts.items[inst].ty;
}

fn declare(lower: *Lower, token: Token, inst: u32, ty: Type.Index, is_mutable: bool) Allocator.Error!void {
    lower.names.items[inst] = token;
    try lower.locals.append(lower.gpa, .{
        .name = lower.tree.tokenSlice(token),
        .token = token,
        .inst = inst,
        .ty = ty,
        .is_mutable = is_mutable,
    });
}

fn find(lower: *Lower, text: []const u8) ?*Local {
    var at = lower.locals.items.len;
    while (at > 0) {
        at -= 1;
        const local = &lower.locals.items[at];
        if (std.mem.eql(u8, local.name, text)) return local;
    }
    return null;
}

// Statements

fn block(lower: *Lower, node: Ast.Node.Index) Allocator.Error!void {
    const stmts = switch (lower.tree.viewOf(node)) {
        .block => |it| it,
        else => return,
    };
    const depth = lower.locals.items.len;
    defer lower.locals.shrinkRetainingCapacity(depth);

    for (stmts) |stmt| try lower.statement(stmt);
}

fn statement(lower: *Lower, node: Ast.Node.Index) Allocator.Error!void {
    switch (lower.tree.viewOf(node)) {
        .var_decl => |it| try lower.localDecl(it),
        .assign => |it| _ = try lower.assign(it),
        .return_stmt => |it| try lower.returnStmt(node, it),
        .block => try lower.block(node),
        else => _ = try lower.expr(node), // evaluated for its effect
    }
}

fn localDecl(lower: *Lower, binding: Ast.View.VarDecl) Allocator.Error!void {
    var inst = try lower.expr(binding.init_expr);
    var ty = lower.typeOf(inst);

    if (binding.type_expr.unwrap()) |annotation| {
        const declared = try lower.sema.evalTypeExpr(annotation);
        if (!lower.fits(ty, declared)) inst = try lower.fail(.{
            .tag = .type_mismatch,
            .token = lower.mainToken(binding.init_expr),
            .message = try lower.print("'{s}' is declared '{s}', but its value is '{s}'", .{
                lower.tree.tokenSlice(binding.name_token),
                try lower.typeName(declared),
                try lower.typeName(ty),
            }),
            .text = try lower.thisIs(ty),
            .marks = try lower.mark(
                lower.mainToken(annotation),
                try lower.print("declared '{s}' here", .{try lower.typeName(declared)}),
            ),
        });
        ty = declared;
    }

    try lower.declare(binding.name_token, inst, ty, binding.is_mutable);
}

fn returnStmt(lower: *Lower, node: Ast.Node.Index, value: Ast.Node.OptionalIndex) Allocator.Error!void {
    const fn_name = lower.tree.tokenSlice(lower.function.name_token);
    var operand: Nir.OptionalIndex = .none;

    if (value.unwrap()) |expr_node| {
        const inst = try lower.expr(expr_node);
        operand = @enumFromInt(inst);
        const got = lower.typeOf(inst);
        if (!lower.fits(got, lower.returns)) try lower.report(.{
            .tag = .type_mismatch,
            .token = lower.mainToken(expr_node),
            .message = try lower.print("'{s}' returns '{s}', but this is '{s}'", .{
                fn_name, try lower.typeName(lower.returns), try lower.typeName(got),
            }),
            .text = try lower.thisIs(got),
            .marks = try lower.returnTypeMark(),
        });
    } else if (lower.returns != .void and lower.returns != .poisoned) {
        try lower.report(.{
            .tag = .type_mismatch,
            .token = lower.mainToken(node),
            .message = try lower.print("'{s}' returns '{s}', but this 'return' has no value", .{
                fn_name, try lower.typeName(lower.returns),
            }),
            .text = "nothing is returned here",
            .marks = try lower.returnTypeMark(),
        });
    }

    _ = try lower.add(.{
        .tag = .ret,
        .token = lower.mainToken(node),
        .last = lower.tree.lastToken(node),
        .ty = .void,
        .lhs = @intFromEnum(operand),
    });
}

/// `x = e` points the name at a new instruction; `a.f = e` stores.
fn assign(lower: *Lower, node: Ast.View.Assign) Allocator.Error!u32 {
    switch (lower.tree.viewOf(node.lhs)) {
        .ident => |token| return lower.assignLocal(token, node.rhs),
        .field_access => |access| return lower.assignField(node, access),
        else => return lower.fail(.{
            .tag = .not_assignable,
            .token = lower.mainToken(node.lhs),
        }),
    }
}

fn assignLocal(lower: *Lower, token: Token, rhs: Ast.Node.Index) Allocator.Error!u32 {
    const value = try lower.expr(rhs);
    const text = lower.tree.tokenSlice(token);
    const local = lower.find(text) orelse
        return lower.fail(.{ .tag = .undefined_name, .token = token });

    const held = local.ty;
    const declared_at = local.token;
    if (!local.is_mutable) return lower.fail(.{
        .tag = .not_mutable,
        .token = token,
        .message = try lower.print("'{s}' is a 'let', so it cannot be assigned to", .{text}),
        .marks = try lower.mark(declared_at, "declared here, as a 'let'"),
        .notes = try lower.notes(&.{.{
            .kind = .help,
            .text = "declare it with 'var' if it has to change",
        }}),
    });

    const got = lower.typeOf(value);
    if (!lower.fits(got, held)) try lower.report(.{
        .tag = .type_mismatch,
        .token = lower.mainToken(rhs),
        .message = try lower.print("'{s}' holds '{s}', but this is '{s}'", .{
            text, try lower.typeName(held), try lower.typeName(got),
        }),
        .text = try lower.thisIs(got),
        .marks = try lower.mark(declared_at, try lower.print("'{s}' was declared here", .{text})),
    });

    lower.names.items[value] = token;
    local.inst = value;
    return value;
}

fn assignField(lower: *Lower, node: Ast.View.Assign, access: Ast.View.FieldAccess) Allocator.Error!u32 {
    const target = try lower.expr(node.lhs);
    const value = try lower.expr(node.rhs);
    const held = lower.typeOf(target);
    const got = lower.typeOf(value);
    const field_name = lower.tree.tokenSlice(access.name_token);

    if (!lower.fits(got, held)) try lower.report(.{
        .tag = .type_mismatch,
        .token = lower.mainToken(node.rhs),
        .message = try lower.print("field '{s}' holds '{s}', but this is '{s}'", .{
            field_name, try lower.typeName(held), try lower.typeName(got),
        }),
        .text = try lower.thisIs(got),
        .marks = try lower.mark(access.name_token, try lower.print("'{s}' is '{s}'", .{
            field_name, try lower.typeName(held),
        })),
    });

    return lower.add(.{
        .tag = .store_field,
        // The value, not the destination: it is what a lifetime error is about.
        .token = lower.tree.firstToken(node.rhs),
        .last = lower.tree.lastToken(node.rhs),
        .ty = .void,
        .lhs = target,
        .rhs = value,
    });
}

// Expressions

fn expr(lower: *Lower, node: Ast.Node.Index) Allocator.Error!u32 {
    switch (lower.tree.viewOf(node)) {
        .number_literal => |token| {
            const ty = try lower.sema.numberLiteralType(token);
            const tag: Inst.Tag = if (ty == .comptime_float) .float else .int;
            return lower.add(.{ .tag = tag, .token = token, .ty = ty });
        },
        .str_literal => |token| return lower.add(.{ .tag = .str, .token = token, .ty = .str }),
        .bool_literal => |it| return lower.add(.{ .tag = .bool, .token = it.token, .ty = .bool }),
        .ident => |token| return lower.name(token),
        .grouped => |inner| return lower.expr(inner),
        .binary => |it| return lower.binary(it),
        .unary => |it| return lower.unary(it),
        .field_access => |it| return lower.fieldOf(try lower.expr(it.lhs), it, node),
        .call => |it| return lower.call(node, it),
        else => return lower.todo(lower.mainToken(node)),
    }
}

/// A local first, then a builtin, then a container declaration.
fn name(lower: *Lower, token: Token) Allocator.Error!u32 {
    const text = lower.tree.tokenSlice(token);
    if (lower.find(text)) |local| return local.inst;

    if (InternPool.builtinNamed(text)) |builtin| return lower.add(.{
        .tag = .decl,
        .token = token,
        .ty = .type,
        .rhs = @intFromEnum(builtin),
    });

    const decl = lower.sema.namespace.find(text) orelse
        return lower.fail(.{ .tag = .undefined_name, .token = token });
    try lower.sema.resolveDecl(decl);
    return lower.add(.{
        .tag = .decl,
        .token = token,
        .ty = decl.ty,
        .rhs = @intFromEnum(decl.value),
    });
}

fn binary(lower: *Lower, node: Ast.View.Binary) Allocator.Error!u32 {
    const lhs = try lower.expr(node.lhs);
    const rhs = try lower.expr(node.rhs);
    const a = lower.typeOf(lhs);
    const b = lower.typeOf(rhs);

    const ty: Type.Index = switch (node.op) {
        .bool_and, .bool_or => blk: {
            try lower.needsBool(node.lhs, a, lower.tree.tokenSlice(node.op_token));
            try lower.needsBool(node.rhs, b, lower.tree.tokenSlice(node.op_token));
            break :blk .bool;
        },
        .equal, .not_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal => blk: {
            if (lower.unify(a, b) == null) try lower.reportOperands(node, a, b);
            break :blk .bool;
        },
        else => lower.unify(a, b) orelse blk: {
            try lower.reportOperands(node, a, b);
            break :blk .poisoned;
        },
    };

    return lower.add(.{ .tag = .binary, .token = node.op_token, .ty = ty, .lhs = lhs, .rhs = rhs });
}

fn unary(lower: *Lower, node: Ast.View.Unary) Allocator.Error!u32 {
    const operand = try lower.expr(node.operand);
    const ty = lower.typeOf(operand);
    if (node.op == .bool_not) try lower.needsBool(node.operand, ty, "!");
    return lower.add(.{ .tag = .unary, .token = node.op_token, .ty = ty, .lhs = operand });
}

fn fieldOf(lower: *Lower, base: u32, access: Ast.View.FieldAccess, node: Ast.Node.Index) Allocator.Error!u32 {
    // Through a pointer as readily as into a value: `n.next.value` never says which.
    const owner = Type.pointeeOf(lower.pool, lower.typeOf(base)) orelse lower.typeOf(base);
    // An `Arena` method is not a field, and `call` has already taken those.
    if (lower.pool.keyOf(owner) != .struct_type or !lower.pool.isDefined(owner)) {
        return lower.todo(access.name_token);
    }

    const text = lower.tree.tokenSlice(access.name_token);
    const wanted = try lower.pool.internString(lower.gpa, text);
    const at = lower.pool.findStructField(owner, wanted) orelse return lower.fail(.{
        .tag = .no_such_field,
        .token = access.name_token,
        .message = try lower.print("'{s}' has no field named '{s}'", .{
            try lower.typeName(owner), text,
        }),
        .notes = try lower.notes(&.{.{
            .kind = .note,
            .text = try lower.print("'{s}' has {s}", .{
                try lower.typeName(owner), try lower.fieldList(owner),
            }),
        }}),
    });

    return lower.add(.{
        .tag = .field,
        .token = lower.tree.firstToken(node),
        .last = access.name_token,
        .ty = lower.pool.structFieldTypes(owner)[at],
        .lhs = base,
        .rhs = at,
    });
}

fn call(lower: *Lower, node: Ast.Node.Index, it: Ast.View.Call) Allocator.Error!u32 {
    const token = lower.mainToken(node);
    const span: Span = .{ lower.tree.firstToken(node), lower.tree.lastToken(node) };

    const callee = switch (lower.tree.viewOf(it.callee)) {
        // Arena's operations are builtins rather than fields, so the receiver decides
        // before anything looks for a field of that name.
        .field_access => |access| blk: {
            const receiver = try lower.expr(access.lhs);
            if (lower.typeOf(receiver) == .Arena or lower.isArenaType(receiver)) {
                return lower.arenaMethod(receiver, access.name_token, it.args, token, span);
            }
            break :blk try lower.fieldOf(receiver, access, it.callee);
        },
        else => try lower.expr(it.callee),
    };

    const callee_ty = lower.typeOf(callee);
    const signature = switch (lower.pool.keyOf(callee_ty)) {
        .func => |func| func,
        else => {
            for (it.args) |arg| _ = try lower.expr(arg);
            if (callee_ty == .poisoned) return lower.todo(token);
            return lower.fail(.{
                .tag = .not_callable,
                .token = lower.insts.items[callee].token,
                .message = try lower.print("this is '{s}', which is not a function", .{
                    try lower.typeName(callee_ty),
                }),
            });
        },
    };

    const callee_name = lower.tree.tokenSlice(lower.insts.items[callee].token);
    const start: u32 = @intCast(lower.extra.items.len);
    try lower.extra.append(lower.gpa, @intCast(it.args.len));

    for (it.args, 0..) |arg, at| {
        const value = try lower.expr(arg);
        const got = lower.typeOf(value);
        if (at < signature.params.len and !lower.fits(got, signature.params[at])) {
            try lower.report(.{
                .tag = .type_mismatch,
                .token = lower.mainToken(arg),
                .message = try lower.print("argument {d} of '{s}' is '{s}', but this is '{s}'", .{
                    at + 1, callee_name, try lower.typeName(signature.params[at]), try lower.typeName(got),
                }),
                .text = try lower.thisIs(got),
            });
        }
        try lower.extra.append(lower.gpa, value);
    }

    if (it.args.len != signature.params.len) try lower.report(.{
        .tag = .wrong_arg_count,
        .token = token,
        .message = try lower.print("'{s}' takes {d} argument{s}, but {d} {s} given", .{
            callee_name,
            signature.params.len,
            if (signature.params.len == 1) "" else "s",
            it.args.len,
            if (it.args.len == 1) "was" else "were",
        }),
        .marks = try lower.mark(lower.insts.items[callee].token, try lower.print("'{s}' is '{s}'", .{
            callee_name, try lower.typeName(callee_ty),
        })),
    });

    return lower.add(.{
        .tag = .call,
        .token = span[0],
        .last = span[1],
        .ty = signature.return_type,
        .lhs = callee,
        .rhs = start,
    });
}

/// Whether `inst` names the `Arena` type itself, as `Arena.init()` does.
fn isArenaType(lower: *const Lower, inst: u32) bool {
    const it = lower.insts.items[inst];
    return it.tag == .decl and it.ty == .type and
        @as(Type.Index, @enumFromInt(it.rhs)) == .Arena;
}

const Method = enum { init, child, create, copy, reset, destroy };

const methods = std.StaticStringMap(Method).initComptime(.{
    .{ "init", Method.init },
    .{ "child", Method.child },
    .{ "create", Method.create },
    .{ "copy", Method.copy },
    .{ "reset", Method.reset },
    .{ "destroy", Method.destroy },
});

/// The arena operations the memory model is written in terms of.
fn arenaMethod(
    lower: *Lower,
    receiver: u32,
    name_token: Token,
    args: []const Ast.Node.Index,
    token: Token,
    span: Span,
) Allocator.Error!u32 {
    const text = lower.tree.tokenSlice(name_token);
    const method = methods.get(text) orelse return lower.fail(.{
        .tag = .no_such_field,
        .token = name_token,
        .message = try lower.print("'Arena' has no operation named '{s}'", .{text}),
    });

    const wanted: usize = switch (method) {
        .create, .copy => 1,
        else => 0,
    };
    if (args.len != wanted) return lower.fail(.{
        .tag = .wrong_arg_count,
        .token = token,
        .message = try lower.print("'{s}' takes {d} argument{s}, but {d} were given", .{
            text, wanted, if (wanted == 1) "" else "s", args.len,
        }),
    });

    return switch (method) {
        .init => lower.add(.{ .tag = .arena_init, .token = span[0], .last = span[1], .ty = .Arena }),
        .child => lower.add(.{
            .tag = .arena_child,
            .token = span[0],
            .last = span[1],
            .ty = .Arena,
            .lhs = receiver,
        }),
        .reset, .destroy => lower.add(.{
            .tag = if (method == .reset) .arena_reset else .arena_destroy,
            .token = span[0],
            .last = span[1],
            .ty = .void,
            .lhs = receiver,
        }),
        .create => blk: {
            const of = try lower.sema.evalTypeExpr(args[0]);
            const ty = if (of == .poisoned) .poisoned else try lower.pool.intern(
                lower.gpa,
                .{ .pointer = .{ .pointee = of, .is_mutable = true } },
            );
            break :blk lower.add(.{
                .tag = .arena_create,
                .token = span[0],
                .last = span[1],
                .ty = ty,
                .lhs = receiver,
            });
        },
        .copy => blk: {
            const value = try lower.expr(args[0]);
            const ty = lower.typeOf(value);
            // A copy holding a pointer would be relabelled without moving what it reaches.
            if (ty != .poisoned and lower.pool.isDefined(ty) and !Type.isCopyable(lower.pool, ty)) {
                try lower.report(.{
                    .tag = .copy_holds_pointer,
                    .token = lower.mainToken(args[0]),
                    .message = try lower.print("'{s}' holds a pointer, so it cannot be copied", .{
                        try lower.typeName(ty),
                    }),
                    .text = try lower.thisIs(ty),
                    .notes = try lower.copyNotes(ty),
                });
            }
            break :blk lower.add(.{
                .tag = .arena_copy,
                .token = span[0],
                .last = span[1],
                .ty = ty,
                .lhs = receiver,
                .rhs = value,
            });
        },
    };
}

// Checking

/// Poison on either side counts as fitting, since whatever produced it already reported.
fn fits(lower: *const Lower, from: Type.Index, into: Type.Index) bool {
    if (from == .poisoned or into == .poisoned) return true;
    return Type.coerce(lower.pool, from, into) != null;
}

/// The type both sides settle on, or null when neither reaches the other.
fn unify(lower: *const Lower, a: Type.Index, b: Type.Index) ?Type.Index {
    if (a == .poisoned or b == .poisoned) return .poisoned;
    if (Type.coerce(lower.pool, a, b) != null) return b;
    if (Type.coerce(lower.pool, b, a) != null) return a;
    return null;
}

fn needsBool(lower: *Lower, node: Ast.Node.Index, ty: Type.Index, op: []const u8) Allocator.Error!void {
    if (lower.fits(ty, .bool)) return;
    try lower.report(.{
        .tag = .type_mismatch,
        .token = lower.mainToken(node),
        .message = try lower.print("'{s}' needs 'bool', but this is '{s}'", .{
            op, try lower.typeName(ty),
        }),
        .text = try lower.thisIs(ty),
    });
}

fn reportOperands(lower: *Lower, node: Ast.View.Binary, a: Type.Index, b: Type.Index) Allocator.Error!void {
    try lower.report(.{
        .tag = .type_mismatch,
        .token = node.op_token,
        .message = try lower.print("'{s}' cannot combine '{s}' and '{s}'", .{
            lower.tree.tokenSlice(node.op_token),
            try lower.typeName(a),
            try lower.typeName(b),
        }),
        .marks = try lower.marks(&.{
            .{ .token = lower.mainToken(node.lhs), .text = try lower.thisIs(a) },
            .{ .token = lower.mainToken(node.rhs), .text = try lower.thisIs(b) },
        }),
    });
}

/// Points at the return type in the signature, which is what a `return` is judged by.
fn returnTypeMark(lower: *Lower) Allocator.Error![]const Mark {
    const node = lower.function.return_type.unwrap() orelse return &.{};
    return lower.mark(
        lower.mainToken(node),
        try lower.print("declared to return '{s}'", .{try lower.typeName(lower.returns)}),
    );
}

/// `fields 'value' and 'next'`, for a diagnostic that has to say what a type does have.
fn fieldList(lower: *Lower, owner: Type.Index) Allocator.Error![]const u8 {
    const names = lower.pool.structFieldNames(owner);
    if (names.len == 0) return "no fields";

    const arena = lower.sema.diagnostics.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, if (names.len > 1) "fields " else "field ");
    for (names, 0..) |field_name, at| {
        if (at > 0) try out.appendSlice(arena, if (at + 1 == names.len) " and " else ", ");
        try out.append(arena, '\'');
        try out.appendSlice(arena, lower.pool.stringBytes(field_name));
        try out.append(arena, '\'');
    }
    return out.items;
}

/// Names the field that makes the type uncopyable, which is the thing to fix.
fn copyNotes(lower: *Lower, ty: Type.Index) Allocator.Error![]const Note {
    const help: Note = .{ .kind = .help, .text = "copy what the pointer reaches, and rebuild around it" };
    if (lower.pool.keyOf(ty) != .struct_type) return lower.notes(&.{help});

    for (lower.pool.structFieldNames(ty), lower.pool.structFieldTypes(ty)) |field_name, field_ty| {
        if (Type.isCopyable(lower.pool, field_ty)) continue;
        return lower.notes(&.{ .{
            .kind = .note,
            .text = try lower.print(
                "'{s}' is '{s}', and a copy moves the value rather than what it points at,\nso the copy would still reach into the arena the original came from.",
                .{ lower.pool.stringBytes(field_name), try lower.typeName(field_ty) },
            ),
        }, help });
    }
    return lower.notes(&.{help});
}

// Wording

fn mainToken(lower: *const Lower, node: Ast.Node.Index) Token {
    return lower.tree.nodeMainToken(node);
}

fn typeName(lower: *Lower, ty: Type.Index) Allocator.Error![]const u8 {
    return lower.sema.typeName(ty);
}

fn thisIs(lower: *Lower, ty: Type.Index) Allocator.Error![]const u8 {
    return lower.print("this is '{s}'", .{try lower.typeName(ty)});
}

fn print(lower: *Lower, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
    return lower.sema.diagnostics.print(fmt, args);
}

fn mark(lower: *Lower, token: Token, text: []const u8) Allocator.Error![]const Mark {
    return lower.sema.diagnostics.mark(token, text);
}

fn marks(lower: *Lower, values: []const Mark) Allocator.Error![]const Mark {
    return lower.sema.diagnostics.marks(values);
}

fn notes(lower: *Lower, values: []const Note) Allocator.Error![]const Note {
    return lower.sema.diagnostics.notes(values);
}
