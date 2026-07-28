//! Lowers one function body to `Nir`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Namespace = @import("Namespace.zig");
const Nir = @import("Nir.zig");
const Sema = @import("Sema.zig");
const Type = @import("Type.zig");
const Value = @import("Value.zig");

const Lower = @This();
const Token = Ast.TokenIndex;
const Inst = Nir.Inst;
const Note = Diagnostic.Note;
const Span = struct { Token, Token };

sema: *Sema,
gpa: Allocator,
types: *Type,
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

/// A name is the instruction that last produced its value. Rebinding points at a new
/// one, which is why no storage slot is needed while bodies are straight line.
const Local = struct {
    name: []const u8,
    token: Token,
    inst: u32,
    is_mutable: bool,
};

pub fn run(sema: *Sema, decl: Namespace.Decl) Allocator.Error!Nir {
    const function = sema.tree.viewOf(decl.node).fn_decl;
    const signature = sema.types.funcOf(decl.value.ty) orelse
        Type.Func{ .params = &.{}, .return_type = .poisoned };

    var lower: Lower = .{
        .sema = sema,
        .gpa = sema.gpa,
        .types = sema.types,
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
            .val = .{ .ty = params[at] },
            .lhs = at,
        });
        try lower.declare(param.name_token, inst, false);
        at += 1;
    }
}

// Building

fn add(lower: *Lower, inst: Inst) Allocator.Error!u32 {
    const at: u32 = @intCast(lower.insts.items.len);
    try lower.insts.append(lower.gpa, inst);
    try lower.names.append(lower.gpa, Nir.none);
    return at;
}

fn todo(lower: *Lower, token: Token) Allocator.Error!u32 {
    return lower.add(.{ .tag = .todo, .token = token, .val = .poisoned });
}

fn report(lower: *Lower, entry: Diagnostic.Entry) Allocator.Error!void {
    try lower.sema.diagnostics.add(entry);
}

/// Reports, and stands in for the value that could not be produced.
fn fail(lower: *Lower, entry: Diagnostic.Entry) Allocator.Error!u32 {
    try lower.report(entry);
    return lower.todo(entry.token);
}

fn valOf(lower: *const Lower, inst: u32) Value {
    return lower.insts.items[inst].val;
}

fn typeOf(lower: *const Lower, inst: u32) Type.Index {
    return lower.valOf(inst).ty;
}

fn declare(lower: *Lower, token: Token, inst: u32, is_mutable: bool) Allocator.Error!void {
    lower.names.items[inst] = token;
    try lower.locals.append(lower.gpa, .{
        .name = lower.tree.tokenSlice(token),
        .token = token,
        .inst = inst,
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

/// Gives a value the type a binding assigns it. `keep_known` is false for a `var`,
/// since a mutable slot is a runtime value whatever initialized it.
fn coerced(lower: *Lower, inst: u32, into: Type.Index, token: Token, keep_known: bool) Allocator.Error!u32 {
    const old = lower.valOf(inst);
    const val: Value = .{ .ty = into, .known = if (keep_known) old.known else .runtime };
    if (std.meta.eql(val, old)) return inst;
    return lower.add(.{ .tag = .coerce, .token = token, .val = val, .lhs = inst });
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
    try lower.endScope(depth);
}

/// An arena dies at the end of the scope that made it. Already released is already gone,
/// which is what keeps a `destroy` the source wrote from happening twice.
fn endScope(lower: *Lower, depth: usize) Allocator.Error!void {
    var at = lower.locals.items.len;
    while (at > depth) {
        at -= 1;
        const local = lower.locals.items[at];
        switch (lower.insts.items[local.inst].tag) {
            .arena_init, .arena_child => {},
            else => continue,
        }
        if (lower.isReleased(local.inst)) continue;
        _ = try lower.add(.{
            .tag = .arena_end,
            .token = local.token,
            .val = .{ .ty = .void },
            .lhs = local.inst,
        });
    }
}

fn isReleased(lower: *const Lower, inst: u32) bool {
    for (lower.insts.items) |it| {
        switch (it.tag) {
            .arena_destroy, .arena_end => if (it.lhs == inst) return true,
            else => {},
        }
    }
    return false;
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

/// A `let` stays comptime when its value is known. A `var` is a runtime slot, so an
/// untyped comptime initializer becomes `i64` or `f64` and knownness ends here.
fn localDecl(lower: *Lower, binding: Ast.View.VarDecl) Allocator.Error!void {
    var inst = try lower.expr(binding.init_expr);

    if (binding.type_expr.unwrap()) |annotation| {
        const declared = try lower.sema.evalTypeExpr(annotation);
        const fits = try lower.sema.expect(declared, lower.valOf(inst), binding.init_expr, .{
            .annotation = .{ .name = binding.name_token, .site = lower.mainToken(annotation) },
        });
        inst = try lower.coerced(inst, declared, binding.name_token, fits and !binding.is_mutable);
    } else if (binding.is_mutable) {
        const runtime = Type.runtime(lower.typeOf(inst));
        inst = try lower.coerced(inst, runtime, binding.name_token, false);
    }

    try lower.declare(binding.name_token, inst, binding.is_mutable);
}

fn returnStmt(lower: *Lower, node: Ast.Node.Index, value: Ast.Node.OptionalIndex) Allocator.Error!void {
    var operand: u32 = Nir.none;
    var returned: Value = .{ .ty = .void };
    var blame = node;

    if (value.unwrap()) |expr_node| {
        operand = try lower.expr(expr_node);
        returned = lower.valOf(operand);
        blame = expr_node;
    }

    _ = try lower.sema.expect(lower.returns, returned, blame, .{ .returned = .{
        .fn_name = lower.function.name_token,
        .site = if (lower.function.return_type.unwrap()) |n| lower.mainToken(n) else null,
    } });

    try lower.endScope(0);

    _ = try lower.add(.{
        .tag = .ret,
        .token = lower.mainToken(node),
        .last = lower.tree.lastToken(node),
        .val = .{ .ty = .void },
        .lhs = operand,
    });
}

/// `x = e` points the name at a new instruction, where `a.f = e` stores.
fn assign(lower: *Lower, node: Ast.View.Assign) Allocator.Error!u32 {
    switch (lower.tree.viewOf(node.lhs)) {
        .ident => |token| return lower.assignLocal(token, node.rhs),
        .field_access => |access| return lower.assignField(node, access),
        else => return lower.fail(.{
            .tag = .not_assignable,
            .token = lower.tree.firstToken(node.lhs),
            .last = lower.tree.lastToken(node.lhs),
            .text = "this is a value, not a place to put one",
            .notes = try lower.notes(&.{.{
                .kind = .note,
                .text = "only a name or a field of one can be assigned to",
            }}),
        }),
    }
}

fn assignLocal(lower: *Lower, token: Token, rhs: Ast.Node.Index) Allocator.Error!u32 {
    const value = try lower.expr(rhs);
    const text = lower.tree.tokenSlice(token);
    const local = lower.find(text) orelse
        return lower.fail(try lower.undefinedName(token, text));

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

    const held = lower.typeOf(local.inst);
    _ = try lower.sema.expect(held, lower.valOf(value), rhs, .{ .assigned = .{
        .name = token,
        .site = declared_at,
    } });

    const rebound = try lower.coerced(value, held, token, false);
    lower.names.items[rebound] = token;
    local.inst = rebound;
    return rebound;
}

fn assignField(lower: *Lower, node: Ast.View.Assign, access: Ast.View.FieldAccess) Allocator.Error!u32 {
    const target = try lower.expr(node.lhs);
    const value = try lower.expr(node.rhs);

    _ = try lower.sema.expect(lower.typeOf(target), lower.valOf(value), node.rhs, .{
        .field_store = .{ .name = access.name_token },
    });

    return lower.add(.{
        .tag = .store_field,
        // The value, not the destination, since that is what a lifetime error is about.
        .token = lower.tree.firstToken(node.rhs),
        .last = lower.tree.lastToken(node.rhs),
        .val = .{ .ty = .void },
        .lhs = target,
        .rhs = value,
    });
}

// Expressions

fn expr(lower: *Lower, node: Ast.Node.Index) Allocator.Error!u32 {
    switch (lower.tree.viewOf(node)) {
        .number_literal, .bool_literal => return lower.add(.{
            .tag = .constant,
            .token = lower.mainToken(node),
            .val = try lower.sema.evalComptime(node),
        }),
        .str_literal => |token| return lower.add(.{ .tag = .str, .token = token, .val = .{ .ty = .str } }),
        .ident => |token| return lower.name(token),
        .grouped => |inner| return lower.expr(inner),
        .binary => |it| return lower.binary(node, it),
        .unary => |it| return lower.unary(node, it),
        .field_access => |it| return lower.fieldOf(try lower.expr(it.lhs), it, node),
        .call => |it| return lower.call(node, it),
        else => return lower.todo(lower.mainToken(node)),
    }
}

/// A local first, then a builtin, then a container declaration. A declaration's value
/// arrives with it, which is how a comptime constant crosses declarations.
fn name(lower: *Lower, token: Token) Allocator.Error!u32 {
    const text = lower.tree.tokenSlice(token);
    if (lower.find(text)) |local| return local.inst;

    if (Type.builtinNamed(text)) |builtin| return lower.add(.{
        .tag = .decl,
        .token = token,
        .val = .ofType(builtin),
    });

    const decl = lower.sema.namespace.find(text) orelse
        return lower.fail(try lower.undefinedName(token, text));
    try lower.sema.resolveDecl(decl);
    return lower.add(.{ .tag = .decl, .token = token, .val = decl.value });
}

fn binary(lower: *Lower, node: Ast.Node.Index, it: Ast.View.Binary) Allocator.Error!u32 {
    const lhs = try lower.expr(it.lhs);
    const rhs = try lower.expr(it.rhs);
    return lower.add(.{
        .tag = .binary,
        .token = it.op_token,
        .val = try lower.sema.binOp(node, it, lower.valOf(lhs), lower.valOf(rhs)),
        .lhs = lhs,
        .rhs = rhs,
    });
}

fn unary(lower: *Lower, node: Ast.Node.Index, it: Ast.View.Unary) Allocator.Error!u32 {
    const operand = try lower.expr(it.operand);
    return lower.add(.{
        .tag = .unary,
        .token = it.op_token,
        .val = try lower.sema.unOp(node, it, lower.valOf(operand)),
        .lhs = operand,
    });
}

fn fieldOf(lower: *Lower, base: u32, access: Ast.View.FieldAccess, node: Ast.Node.Index) Allocator.Error!u32 {
    // Through a pointer as readily as into a value, since `n.next` never says which.
    const owner = lower.types.pointeeOf(lower.typeOf(base)) orelse lower.typeOf(base);
    // An `Arena` method is not a field, and `call` has already taken those.
    if (!lower.types.isStruct(owner) or !lower.types.isDefined(owner)) {
        return lower.todo(access.name_token);
    }

    const text = lower.tree.tokenSlice(access.name_token);
    const wanted = try lower.types.internString(lower.gpa, text);
    const at = lower.types.findField(owner, wanted) orelse return lower.fail(.{
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
        .val = .{ .ty = lower.types.fieldTypes(owner)[at] },
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
                return lower.arenaMethod(node, receiver, access.name_token, it.args);
            }
            break :blk try lower.fieldOf(receiver, access, it.callee);
        },
        else => try lower.expr(it.callee),
    };

    const callee_ty = lower.typeOf(callee);
    // Named after what the source wrote, never after the instruction that produced the
    // value. A local holding `1 + 2.5` was made by a `+` somewhere else entirely.
    const written = lower.calleeName(it.callee);

    const signature = lower.types.funcOf(callee_ty) orelse {
        for (it.args) |arg| _ = try lower.expr(arg);
        if (callee_ty == .poisoned) return lower.todo(token);
        return lower.fail(.{
            .tag = .not_callable,
            .token = lower.tree.firstToken(it.callee),
            .last = lower.tree.lastToken(it.callee),
            .message = if (written) |text|
                try lower.print("'{s}' is '{s}', which cannot be called", .{
                    text, try lower.typeName(callee_ty),
                })
            else
                try lower.print("this is '{s}', which cannot be called", .{
                    try lower.typeName(callee_ty),
                }),
            .text = try lower.print("called here, but this is '{s}'", .{
                try lower.typeName(callee_ty),
            }),
            .marks = try lower.declaredMark(it.callee, callee_ty),
        });
    };

    const callee_name = written orelse "this";
    const start: u32 = @intCast(lower.extra.items.len);
    try lower.extra.append(lower.gpa, @intCast(it.args.len));

    for (it.args, 0..) |arg, at| {
        const value = try lower.expr(arg);
        if (at < signature.params.len) {
            _ = try lower.sema.expect(signature.params[at], lower.valOf(value), arg, .{
                .argument = .{
                    .position = at,
                    .callee = callee_name,
                    .site = lower.paramSite(it.callee, at),
                },
            });
        }
        try lower.extra.append(lower.gpa, value);
    }

    if (it.args.len != signature.params.len) try lower.report(.{
        .tag = .wrong_arg_count,
        .token = span[0],
        .last = span[1],
        .message = try lower.print("'{s}' takes {d} argument{s}, but {d} {s} given", .{
            callee_name,
            signature.params.len,
            if (signature.params.len == 1) "" else "s",
            it.args.len,
            if (it.args.len == 1) "was" else "were",
        }),
        .text = try lower.print("{d} given here", .{it.args.len}),
        .marks = try lower.declaredMark(it.callee, callee_ty),
    });

    return lower.add(.{
        .tag = .call,
        .token = span[0],
        .last = span[1],
        .val = .{ .ty = signature.return_type },
        .lhs = callee,
        .rhs = start,
    });
}

/// Locals are offered too, since a misspelled local is the likeliest slip in a body.
fn undefinedName(lower: *Lower, token: Token, text: []const u8) Allocator.Error!Diagnostic.Entry {
    var closest = lower.sema.closestTo(text);
    for (lower.locals.items) |local| closest.offer(local.name);
    return .{
        .tag = .undefined_name,
        .token = token,
        .text = "not found in this scope",
        .notes = try lower.sema.didYouMean(closest),
    };
}

/// What the source called the callee, which is not what produced its value.
fn calleeName(lower: *Lower, node: Ast.Node.Index) ?[]const u8 {
    return switch (lower.tree.viewOf(node)) {
        .ident => |token| lower.tree.tokenSlice(token),
        .field_access => |access| lower.tree.tokenSlice(access.name_token),
        else => null,
    };
}

/// Marks where the callee's name was declared, so a bad call shows both ends of itself.
fn declaredMark(
    lower: *Lower,
    node: Ast.Node.Index,
    ty: Type.Index,
) Allocator.Error![]const Diagnostic.Mark {
    const token = switch (lower.tree.viewOf(node)) {
        .ident => |it| it,
        else => return &.{},
    };
    const text = lower.tree.tokenSlice(token);
    const at = if (lower.find(text)) |local|
        local.token
    else if (lower.sema.namespace.find(text)) |decl|
        decl.name_token
    else
        return &.{};

    return lower.mark(at, try lower.print("'{s}' is declared here, as '{s}'", .{
        text, try lower.typeName(ty),
    }));
}

/// The parameter's declaration site, when the callee names a function directly.
fn paramSite(lower: *Lower, callee_node: Ast.Node.Index, at: usize) ?Token {
    const token = switch (lower.tree.viewOf(callee_node)) {
        .ident => |t| t,
        else => return null,
    };
    const decl = lower.sema.namespace.find(lower.tree.tokenSlice(token)) orelse return null;
    const function = switch (lower.tree.viewOf(decl.node)) {
        .fn_decl => |f| f,
        else => return null,
    };
    if (at >= function.params.len) return null;
    return switch (lower.tree.viewOf(function.params[at])) {
        .param => |p| p.name_token,
        else => null,
    };
}

/// Whether `inst` names the `Arena` type itself, as `Arena.init()` does.
fn isArenaType(lower: *const Lower, inst: u32) bool {
    const it = lower.insts.items[inst];
    return it.tag == .decl and it.val.asType() == .Arena;
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
    node: Ast.Node.Index,
    receiver: u32,
    name_token: Token,
    args: []const Ast.Node.Index,
) Allocator.Error!u32 {
    const span: Span = .{ lower.tree.firstToken(node), lower.tree.lastToken(node) };
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
        .token = span[0],
        .last = span[1],
        .message = try lower.print("'{s}' takes {d} argument{s}, but {d} {s} given", .{
            text,
            wanted,
            if (wanted == 1) "" else "s",
            args.len,
            if (args.len == 1) "was" else "were",
        }),
        .text = try lower.print("{d} given here", .{args.len}),
    });

    return switch (method) {
        .init => lower.add(.{
            .tag = .arena_init,
            .token = span[0],
            .last = span[1],
            .val = .{ .ty = .Arena },
        }),
        .child => lower.add(.{
            .tag = .arena_child,
            .token = span[0],
            .last = span[1],
            .val = .{ .ty = .Arena },
            .lhs = receiver,
        }),
        .reset, .destroy => lower.add(.{
            .tag = if (method == .reset) .arena_reset else .arena_destroy,
            .token = span[0],
            .last = span[1],
            .val = .{ .ty = .void },
            .lhs = receiver,
        }),
        .create => blk: {
            const of = try lower.sema.evalTypeExpr(args[0]);
            const ty = if (of == .poisoned)
                Type.Index.poisoned
            else
                try lower.types.pointerType(lower.gpa, of, true);
            break :blk lower.add(.{
                .tag = .arena_create,
                .token = span[0],
                .last = span[1],
                .val = .{ .ty = ty },
                .lhs = receiver,
            });
        },
        .copy => blk: {
            const value = try lower.expr(args[0]);
            const ty = lower.typeOf(value);
            // A copy holding a pointer would be relabelled without moving what it reaches.
            if (ty != .poisoned and lower.types.isDefined(ty) and !lower.types.isCopyable(ty)) {
                try lower.report(.{
                    .tag = .copy_holds_pointer,
                    .token = lower.mainToken(args[0]),
                    .message = try lower.print("'{s}' holds a pointer, so it cannot be copied", .{
                        try lower.typeName(ty),
                    }),
                    .text = try lower.print("this is '{s}'", .{try lower.typeName(ty)}),
                    .notes = try lower.copyNotes(ty),
                });
            }
            break :blk lower.add(.{
                .tag = .arena_copy,
                .token = span[0],
                .last = span[1],
                .val = .{ .ty = ty },
                .lhs = receiver,
                .rhs = value,
            });
        },
    };
}

// Wording

fn mainToken(lower: *const Lower, node: Ast.Node.Index) Token {
    return lower.tree.nodeMainToken(node);
}

fn typeName(lower: *Lower, ty: Type.Index) Allocator.Error![]const u8 {
    return lower.sema.typeName(ty);
}

fn print(lower: *Lower, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
    return lower.sema.diagnostics.print(fmt, args);
}

fn mark(lower: *Lower, token: Token, text: []const u8) Allocator.Error![]const Diagnostic.Mark {
    return lower.sema.diagnostics.mark(token, text);
}

fn notes(lower: *Lower, values: []const Note) Allocator.Error![]const Note {
    return lower.sema.diagnostics.notes(values);
}

/// `fields 'value' and 'next'`, for a diagnostic that has to say what a type does have.
fn fieldList(lower: *Lower, owner: Type.Index) Allocator.Error![]const u8 {
    const names = lower.types.fieldNames(owner);
    if (names.len == 0) return "no fields";

    const arena = lower.sema.diagnostics.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, if (names.len > 1) "fields " else "field ");
    for (names, 0..) |field_name, at| {
        if (at > 0) try out.appendSlice(arena, if (at + 1 == names.len) " and " else ", ");
        try out.append(arena, '\'');
        try out.appendSlice(arena, lower.types.stringBytes(field_name));
        try out.append(arena, '\'');
    }
    return out.items;
}

/// Names the field that makes the type uncopyable, which is the thing to fix.
fn copyNotes(lower: *Lower, ty: Type.Index) Allocator.Error![]const Note {
    const help: Note = .{ .kind = .help, .text = "copy what the pointer reaches, and rebuild around it" };
    if (!lower.types.isStruct(ty)) return lower.notes(&.{help});

    for (lower.types.fieldNames(ty), lower.types.fieldTypes(ty)) |field_name, field_ty| {
        if (lower.types.isCopyable(field_ty)) continue;
        return lower.notes(&.{ .{
            .kind = .note,
            .text = try lower.print(
                "'{s}' is '{s}', and a copy moves the value rather than what it points at,\nso the copy would still reach into the arena the original came from.",
                .{ lower.types.stringBytes(field_name), try lower.typeName(field_ty) },
            ),
        }, help });
    }
    return lower.notes(&.{help});
}
