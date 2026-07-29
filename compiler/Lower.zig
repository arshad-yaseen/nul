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
const Ref = Nir.Ref;
const Note = Diagnostic.Note;

/// First and last token of a source range, which is what a label underlines.
const Span = struct { Token, Token };

/// Types, coercion, and folding are all asked of this, so lowering only decides shape.
sema: *Sema,
gpa: Allocator,
types: *Type,
tree: *const Ast,
/// The body being lowered.
function: Ast.View.FnDecl,
/// What a `return` is checked against.
returns: Type.Index,
/// The graph under construction.
b: Nir.Builder,
/// Innermost last, so a backward scan finds the name that shadows.
locals: std.ArrayList(Local) = .empty,
/// Innermost last. `break` and `continue` jump to the top one's targets.
loops: std.ArrayList(Loop) = .empty,
/// Argument lists under construction, committed to the graph in one piece.
scratch: std.ArrayList(Ref) = .empty,

/// A name in scope, from a parameter or a `let` or `var`.
const Local = struct {
    /// Source bytes, borrowed from the tree.
    name: []const u8,
    /// Where it was declared, which is what a diagnostic points back at.
    token: Token,
    binding: Binding,
    is_mutable: bool,
};

/// `value` is the instruction that produced it, `slot` is an `alloc` to load and store.
const Binding = union(enum) {
    value: Ref,
    slot: Ref,
};

const Loop = struct {
    /// Where the condition is tested, and where `continue` goes.
    head: Nir.Block.Ref,
    /// Past the loop, where `break` goes.
    exit: Nir.Block.Ref,
    /// Depth at the top of the body, so a jump out knows which scopes it leaves.
    locals_depth: usize,
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
        .b = .{ .gpa = sema.gpa },
    };
    defer lower.locals.deinit(lower.gpa);
    defer lower.loops.deinit(lower.gpa);
    defer lower.scratch.deinit(lower.gpa);
    errdefer lower.b.deinit();

    lower.b.activate(try lower.b.reserve());
    try lower.bindParams(signature.params);
    try lower.block(function.body);
    try lower.endBody();
    return lower.b.finish();
}

/// Falling off the end is an implicit bare `return`, allowed only when the function
/// returns nothing.
fn endBody(lower: *Lower) Allocator.Error!void {
    if (!lower.b.open) return;
    const end = lower.tree.lastToken(lower.function.body);

    // A join both of whose arms returned is open but has no way in.
    const ends = try lower.b.reaches(lower.b.current);

    if (ends and lower.returns != .void and lower.returns != .poisoned) {
        try lower.report(.{
            .tag = .missing_return,
            .token = end,
            .message = try lower.print("'{s}' returns '{s}', but its end is reachable", .{
                lower.tree.tokenSlice(lower.function.name_token),
                try lower.typeName(lower.returns),
            }),
            .text = "control can reach here with nothing returned",
            .marks = if (lower.function.return_type.unwrap()) |site| try lower.mark(
                lower.mainToken(site),
                try lower.print("declared to return '{s}' here", .{
                    try lower.typeName(lower.returns),
                }),
            ) else &.{},
            .notes = try lower.notes(&.{.{
                .kind = .help,
                .text = "end every path through the body in a 'return'",
            }}),
        });
    }
    lower.b.seal(.{ .ret = .{ .value = null, .token = end, .last = end } });
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
            .data = .{ .arg = at },
            .val = .{ .ty = params[at] },
            .token = param.name_token,
        });
        try lower.declare(param.name_token, .{ .value = inst }, false);
        at += 1;
    }
}

// Building

fn add(lower: *Lower, inst: Nir.Inst) Allocator.Error!Ref {
    return lower.b.add(inst);
}

fn todo(lower: *Lower, token: Token) Allocator.Error!Ref {
    return lower.add(.{ .data = .todo, .val = .poisoned, .token = token });
}

fn report(lower: *Lower, entry: Diagnostic.Entry) Allocator.Error!void {
    try lower.sema.diagnostics.add(entry);
}

/// Reports, and stands in for the value that could not be produced.
fn fail(lower: *Lower, entry: Diagnostic.Entry) Allocator.Error!Ref {
    try lower.report(entry);
    return lower.todo(entry.token);
}

fn storeTo(lower: *Lower, ptr: Ref, value: Ref, token: Token) Allocator.Error!Ref {
    return lower.add(.{
        .data = .{ .store = .{ .ptr = ptr, .value = value } },
        .val = .{ .ty = .void },
        .token = token,
    });
}

fn valOf(lower: *const Lower, ref: Ref) Value {
    return lower.b.valOf(ref);
}

fn typeOf(lower: *const Lower, ref: Ref) Type.Index {
    return lower.b.valOf(ref).ty;
}

fn declare(lower: *Lower, token: Token, binding: Binding, is_mutable: bool) Allocator.Error!void {
    lower.b.setName(switch (binding) {
        .value, .slot => |ref| ref,
    }, token);
    try lower.locals.append(lower.gpa, .{
        .name = lower.tree.tokenSlice(token),
        .token = token,
        .binding = binding,
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

/// `keep_known` is false for a `var`, which is a runtime slot whatever initialized it.
fn coerced(lower: *Lower, ref: Ref, into: Type.Index, token: Token, keep_known: bool) Allocator.Error!Ref {
    const old = lower.valOf(ref);
    const val: Value = .{ .ty = into, .known = if (keep_known) old.known else .runtime };
    if (std.meta.eql(val, old)) return ref;
    return lower.add(.{ .data = .{ .coerce = ref }, .val = val, .token = token });
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
    // A path that already left the function ended every scope as it went.
    if (lower.b.open) try lower.endScope(depth);
}

/// An arena dies at the end of the scope that made it, on whichever path leaves it.
fn endScope(lower: *Lower, depth: usize) Allocator.Error!void {
    var at = lower.locals.items.len;
    while (at > depth) {
        at -= 1;
        const local = lower.locals.items[at];
        const inst = switch (local.binding) {
            .value => |ref| ref,
            .slot => continue, // an arena is never slot-bound
        };
        switch (lower.b.dataOf(inst)) {
            .arena_init, .arena_child => {},
            else => continue,
        }
        _ = try lower.add(.{
            .data = .{ .arena_end = inst },
            .val = .{ .ty = .void },
            .token = local.token,
        });
    }
}

fn statement(lower: *Lower, node: Ast.Node.Index) Allocator.Error!void {
    try lower.b.ensureOpen();
    switch (lower.tree.viewOf(node)) {
        .var_decl => |it| try lower.localDecl(it),
        .assign => |it| _ = try lower.assign(it),
        .return_stmt => |it| try lower.returnStmt(node, it),
        .if_stmt => |it| try lower.ifStmt(node, it),
        .for_stmt => |it| try lower.forStmt(node, it),
        .break_stmt => |token| try lower.jumpStmt(token, .exit),
        .continue_stmt => |token| try lower.jumpStmt(token, .head),
        .block => try lower.block(node),
        else => _ = try lower.expr(node), // evaluated for its effect
    }
}

fn ifStmt(lower: *Lower, node: Ast.Node.Index, it: Ast.View.If) Allocator.Error!void {
    const cond = try lower.expr(it.cond);
    _ = try lower.sema.expect(.bool, lower.valOf(cond), it.cond, .{
        .operand = .{ .op = lower.mainToken(node) },
    });

    const else_node = it.else_node.unwrap();
    const then_b = try lower.b.reserve();
    const else_b: ?Nir.Block.Ref = if (else_node != null) try lower.b.reserve() else null;
    const join = try lower.b.reserve();

    lower.b.seal(.{ .branch = .{ .cond = cond, .then = then_b, .els = else_b orelse join } });

    lower.b.activate(then_b);
    try lower.block(it.then_block);
    if (lower.b.open) lower.b.sealJump(join);

    if (else_node) |els| {
        lower.b.activate(else_b.?);
        // A block, or another `if_stmt` when the source chained `else if`.
        try lower.statement(els);
        if (lower.b.open) lower.b.sealJump(join);
    }

    lower.b.activate(join);
}

fn forStmt(lower: *Lower, node: Ast.Node.Index, it: Ast.View.For) Allocator.Error!void {
    const head = try lower.b.reserve();
    const body = try lower.b.reserve();
    const exit = try lower.b.reserve();

    lower.b.sealJump(head);
    lower.b.activate(head);
    if (it.cond.unwrap()) |cond_node| {
        const cond = try lower.expr(cond_node);
        _ = try lower.sema.expect(.bool, lower.valOf(cond), cond_node, .{
            .operand = .{ .op = lower.mainToken(node) },
        });
        lower.b.seal(.{ .branch = .{ .cond = cond, .then = body, .els = exit } });
    } else {
        lower.b.sealJump(body);
    }

    lower.b.activate(body);
    try lower.loops.append(lower.gpa, .{
        .head = head,
        .exit = exit,
        .locals_depth = lower.locals.items.len,
    });
    try lower.block(it.body);
    _ = lower.loops.pop();
    if (lower.b.open) lower.b.sealJump(head);

    lower.b.activate(exit);
}

/// Jumping out leaves every scope inside the loop, so their arenas end on this path.
fn jumpStmt(lower: *Lower, token: Token, target: enum { exit, head }) Allocator.Error!void {
    const loop = lower.loops.getLastOrNull() orelse {
        try lower.report(.{
            .tag = .not_in_a_loop,
            .token = token,
            .text = "no loop encloses this",
        });
        return;
    };
    try lower.endScope(loop.locals_depth);
    lower.b.sealJump(switch (target) {
        .exit => loop.exit,
        .head => loop.head,
    });
}

/// A `let` stays comptime when known. A `var` is a runtime slot, so an untyped
/// comptime initializer becomes `i64` or `f64` and knownness ends here.
fn localDecl(lower: *Lower, binding: Ast.View.VarDecl) Allocator.Error!void {
    var inst = try lower.expr(binding.init_expr);
    var held = lower.typeOf(inst);

    if (binding.type_expr.unwrap()) |annotation| {
        held = try lower.sema.evalTypeExpr(annotation);
        const fits = try lower.sema.expect(held, lower.valOf(inst), binding.init_expr, .{
            .annotation = .{ .name = binding.name_token, .site = lower.mainToken(annotation) },
        });
        inst = try lower.coerced(inst, held, binding.name_token, fits and !binding.is_mutable);
    } else if (binding.is_mutable) {
        held = Type.runtime(held);
        inst = try lower.coerced(inst, held, binding.name_token, false);
    }

    // An arena stays direct, so cleanup acts on a name meaning one arena.
    if (binding.is_mutable and held != .Arena) {
        const slot = try lower.add(.{
            .data = .alloc,
            .val = .{ .ty = try lower.pointerTo(held) },
            .token = binding.name_token,
        });
        _ = try lower.storeTo(slot, inst, binding.name_token);
        try lower.declare(binding.name_token, .{ .slot = slot }, true);
    } else {
        try lower.declare(binding.name_token, .{ .value = inst }, binding.is_mutable);
    }
}

fn returnStmt(lower: *Lower, node: Ast.Node.Index, value: Ast.Node.OptionalIndex) Allocator.Error!void {
    var operand: ?Ref = null;
    var returned: Value = .{ .ty = .void };
    var blame = node;

    if (value.unwrap()) |expr_node| {
        const ref = try lower.expr(expr_node);
        operand = ref;
        returned = lower.valOf(ref);
        blame = expr_node;
    }

    _ = try lower.sema.expect(lower.returns, returned, blame, .{ .returned = .{
        .fn_name = lower.function.name_token,
        .site = if (lower.function.return_type.unwrap()) |n| lower.mainToken(n) else null,
    } });

    try lower.endScope(0);
    lower.b.seal(.{ .ret = .{
        .value = operand,
        .token = lower.mainToken(node),
        .last = lower.tree.lastToken(node),
    } });
}

/// `x = e` stores into the name's slot, where `a.f = e` stores through the place.
fn assign(lower: *Lower, node: Ast.View.Assign) Allocator.Error!Ref {
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

fn assignLocal(lower: *Lower, token: Token, rhs: Ast.Node.Index) Allocator.Error!Ref {
    const value = try lower.expr(rhs);
    const text = lower.tree.tokenSlice(token);
    const local = lower.find(text) orelse
        return lower.fail(undefinedName(token));

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

    const slot = switch (local.binding) {
        .slot => |s| s,
        // Mutable and yet not a slot, which only an arena is.
        .value => return lower.fail(.{
            .tag = .not_mutable,
            .token = token,
            .message = try lower.print("'{s}' names an arena, so it cannot be reassigned", .{text}),
            .marks = try lower.mark(declared_at, "declared here, as an arena"),
            .notes = try lower.notes(&.{.{
                .kind = .note,
                .text = "cleanup happens where an arena is named. A name that could mean\n" ++
                    "two arenas would make 'reset' and scope cleanup ambiguous.",
            }}),
        }),
    };

    const held = lower.types.pointeeOf(lower.typeOf(slot)) orelse .poisoned;
    _ = try lower.sema.expect(held, lower.valOf(value), rhs, .{ .assigned = .{
        .name = token,
        .site = declared_at,
    } });

    const fitted = try lower.coerced(value, held, token, false);
    return lower.storeTo(slot, fitted, token);
}

fn assignField(lower: *Lower, node: Ast.View.Assign, access: Ast.View.FieldAccess) Allocator.Error!Ref {
    const place = try lower.placeOf(node.lhs);
    const value = try lower.expr(node.rhs);

    const expected = lower.types.pointeeOf(lower.typeOf(place)) orelse .poisoned;
    _ = try lower.sema.expect(expected, lower.valOf(value), node.rhs, .{
        .field_store = .{ .name = access.name_token },
    });

    return lower.add(.{
        .data = .{ .store = .{ .ptr = place, .value = value } },
        .val = .{ .ty = .void },
        // The value, not the destination, since that is what a lifetime error is about.
        .token = lower.tree.firstToken(node.rhs),
        .last = lower.tree.lastToken(node.rhs),
    });
}

/// The memory an assignment target names, as a mutable pointer. A name is its slot
/// or the pointer it holds, and a dotted path narrows with `field_ptr`, so nothing
/// is copied on the way to a write.
fn placeOf(lower: *Lower, node: Ast.Node.Index) Allocator.Error!Ref {
    switch (lower.tree.viewOf(node)) {
        .field_access => |access| {
            var base = try lower.placeOf(access.lhs);
            // A place holding a pointer is crossed by reading it, so the chain
            // continues in the memory it points at.
            while (lower.types.pointerOf(lower.typeOf(base))) |pointer| {
                if (lower.types.pointerOf(pointer.pointee) == null) break;
                base = try lower.add(.{
                    .data = .{ .load = base },
                    .val = .{ .ty = pointer.pointee },
                    .token = lower.tree.firstToken(access.lhs),
                    .last = lower.tree.lastToken(access.lhs),
                });
            }
            const base_ty = lower.typeOf(base);
            if (base_ty == .poisoned) return lower.todo(access.name_token);
            const pointer = lower.types.pointerOf(base_ty) orelse
                return lower.todo(access.name_token);
            if (!pointer.is_mutable) return lower.fail(.{
                .tag = .not_mutable,
                .token = lower.tree.firstToken(access.lhs),
                .last = lower.tree.lastToken(access.lhs),
                .message = try lower.print("writing through '{s}' is not allowed", .{
                    try lower.typeName(base_ty),
                }),
                .text = try lower.print(
                    "this is '{s}', and only a '*var' pointer can be written through",
                    .{try lower.typeName(base_ty)},
                ),
                .notes = try lower.notes(&.{.{
                    .kind = .help,
                    .text = try lower.print("declare it as '{s}' to allow the write", .{
                        try lower.typeName(try lower.pointerTo(pointer.pointee)),
                    }),
                }}),
            });

            const owner = pointer.pointee;
            if (!lower.types.isStruct(owner) or !lower.types.isDefined(owner)) {
                return lower.todo(access.name_token);
            }
            const at = try lower.resolveField(owner, access.name_token) orelse
                return lower.todo(access.name_token);
            const ft = lower.types.fieldTypes(owner)[at];
            return lower.add(.{
                .data = .{ .field_ptr = .{ .base = base, .index = at } },
                .val = .{ .ty = if (ft == .poisoned) .poisoned else try lower.pointerTo(ft) },
                .token = lower.tree.firstToken(node),
                .last = access.name_token,
            });
        },
        .ident => |token| {
            const text = lower.tree.tokenSlice(token);
            if (lower.find(text)) |local| switch (local.binding) {
                .slot => |slot| return slot,
                .value => |inst| {
                    if (lower.types.pointerOf(lower.typeOf(inst)) != null) return inst;
                    if (lower.typeOf(inst) == .poisoned) return lower.todo(token);
                    return lower.valueNotPlace(token, text, local.token, inst);
                },
            };
            const index = lower.sema.namespace.find(text) orelse
                return lower.fail(undefinedName(token));
            try lower.sema.resolveDecl(index);
            return lower.fail(.{
                .tag = .not_assignable,
                .token = token,
                .message = try lower.print("'{s}' is a value, so its fields cannot be assigned", .{text}),
                .text = "a write here would land on a copy",
                .marks = try lower.mark(
                    lower.sema.namespace.decl(index).name_token,
                    "declared here, as a comptime value",
                ),
            });
        },
        else => {
            const inst = try lower.expr(node);
            if (lower.types.pointerOf(lower.typeOf(inst)) != null) return inst;
            if (lower.typeOf(inst) == .poisoned) return lower.todo(lower.tree.firstToken(node));
            return lower.fail(.{
                .tag = .not_assignable,
                .token = lower.tree.firstToken(node),
                .last = lower.tree.lastToken(node),
                .text = "this is a value, not memory that can be assigned",
            });
        },
    }
}

/// Writing a field of a by-value binding would write a copy nothing keeps.
fn valueNotPlace(lower: *Lower, token: Token, text: []const u8, declared_at: Token, inst: Ref) Allocator.Error!Ref {
    const is_param = lower.b.dataOf(inst) == .arg;
    return lower.fail(.{
        .tag = .not_assignable,
        .token = token,
        .message = try lower.print("'{s}' is a value, so its fields cannot be assigned", .{text}),
        .text = "a write here would land on a copy",
        .marks = try lower.mark(declared_at, if (is_param)
            "declared here, as a value parameter"
        else
            "declared here, as a 'let'"),
        .notes = try lower.notes(&.{.{
            .kind = .help,
            .text = if (is_param)
                try lower.print("take '{s}: *var {s}' to write what the caller passed", .{
                    text, try lower.typeName(lower.typeOf(inst)),
                })
            else
                "declare it with 'var' if it has to change",
        }}),
    });
}

fn pointerTo(lower: *Lower, pointee: Type.Index) Allocator.Error!Type.Index {
    return lower.types.pointerType(lower.gpa, pointee, true);
}

// Expressions

fn expr(lower: *Lower, node: Ast.Node.Index) Allocator.Error!Ref {
    switch (lower.tree.viewOf(node)) {
        .number_literal, .bool_literal => return lower.add(.{
            .data = .constant,
            .val = try lower.sema.evalComptime(node),
            .token = lower.mainToken(node),
        }),
        .str_literal => |token| return lower.add(.{
            .data = .str,
            .val = .{ .ty = .str },
            .token = token,
        }),
        .ident => |token| return lower.name(token),
        .grouped => |inner| return lower.expr(inner),
        .binary => |it| return lower.binary(node, it),
        .unary => |it| return lower.unary(node, it),
        .field_access => |it| return lower.fieldOf(try lower.expr(it.lhs), it, node),
        .call => |it| return lower.call(node, it),
        else => return lower.todo(lower.mainToken(node)),
    }
}

/// A local first, then a builtin, then a container declaration, whose value arrives
/// with it, which is how a comptime constant crosses declarations.
fn name(lower: *Lower, token: Token) Allocator.Error!Ref {
    const text = lower.tree.tokenSlice(token);
    if (lower.find(text)) |local| switch (local.binding) {
        .value => |inst| return inst,
        .slot => |slot| {
            const load = try lower.add(.{
                .data = .{ .load = slot },
                .val = .{ .ty = lower.types.pointeeOf(lower.typeOf(slot)) orelse .poisoned },
                .token = token,
            });
            // Named after the declaration, where the reader looks the name up.
            lower.b.setName(load, local.token);
            return load;
        },
    };

    if (Type.builtinNamed(text)) |builtin| return lower.add(.{
        .data = .decl,
        .val = .ofType(builtin),
        .token = token,
    });

    const index = lower.sema.namespace.find(text) orelse
        return lower.fail(undefinedName(token));
    try lower.sema.resolveDecl(index);
    return lower.add(.{ .data = .decl, .val = lower.sema.namespace.decl(index).value, .token = token });
}

fn binary(lower: *Lower, node: Ast.Node.Index, it: Ast.View.Binary) Allocator.Error!Ref {
    switch (it.op) {
        .bool_and, .bool_or => return lower.shortCircuit(node, it),
        else => {},
    }
    const lhs = try lower.expr(it.lhs);
    const rhs = try lower.expr(it.rhs);
    return lower.add(.{
        .data = .{ .binary = .{ .lhs = lhs, .rhs = rhs } },
        .val = try lower.sema.binOp(node, it, lower.valOf(lhs), lower.valOf(rhs)),
        .token = it.op_token,
    });
}

/// The right side runs only when the left leaves the question open, so these lower
/// as control flow with a slot holding the answer.
fn shortCircuit(lower: *Lower, node: Ast.Node.Index, it: Ast.View.Binary) Allocator.Error!Ref {
    const lhs = try lower.expr(it.lhs);
    const slot = try lower.add(.{
        .data = .alloc,
        .val = .{ .ty = try lower.pointerTo(.bool) },
        .token = it.op_token,
    });
    _ = try lower.storeTo(slot, lhs, it.op_token);

    const rhs_b = try lower.b.reserve();
    const join = try lower.b.reserve();
    lower.b.seal(.{ .branch = switch (it.op) {
        .bool_and => .{ .cond = lhs, .then = rhs_b, .els = join },
        .bool_or => .{ .cond = lhs, .then = join, .els = rhs_b },
        else => unreachable,
    } });

    lower.b.activate(rhs_b);
    const rhs = try lower.expr(it.rhs);
    const val = try lower.sema.binOp(node, it, lower.valOf(lhs), lower.valOf(rhs));
    _ = try lower.storeTo(slot, rhs, it.op_token);
    lower.b.sealJump(join);

    lower.b.activate(join);
    return lower.add(.{ .data = .{ .load = slot }, .val = val, .token = it.op_token });
}

fn unary(lower: *Lower, node: Ast.Node.Index, it: Ast.View.Unary) Allocator.Error!Ref {
    const operand = try lower.expr(it.operand);
    return lower.add(.{
        .data = .{ .unary = operand },
        .val = try lower.sema.unOp(node, it, lower.valOf(operand)),
        .token = it.op_token,
    });
}

fn fieldOf(lower: *Lower, base: Ref, access: Ast.View.FieldAccess, node: Ast.Node.Index) Allocator.Error!Ref {
    // Through a pointer as readily as into a value, since `n.next` never says which.
    const base_ty = lower.typeOf(base);
    const owner = lower.types.pointeeOf(base_ty) orelse base_ty;
    // An `Arena` method is not a field, and `call` has already taken those.
    if (!lower.types.isStruct(owner) or !lower.types.isDefined(owner)) {
        return lower.todo(access.name_token);
    }
    const at = try lower.resolveField(owner, access.name_token) orelse
        return lower.todo(access.name_token);
    const ft = lower.types.fieldTypes(owner)[at];

    // Through a pointer the read narrows it and loads, copying nothing on the way.
    // From a value it extracts.
    if (lower.types.pointerOf(base_ty)) |pointer| {
        const place = try lower.add(.{
            .data = .{ .field_ptr = .{ .base = base, .index = at } },
            .val = .{ .ty = if (ft == .poisoned)
                .poisoned
            else
                try lower.types.pointerType(lower.gpa, ft, pointer.is_mutable) },
            .token = lower.tree.firstToken(node),
            .last = access.name_token,
        });
        return lower.add(.{
            .data = .{ .load = place },
            .val = .{ .ty = ft },
            .token = lower.tree.firstToken(node),
            .last = access.name_token,
        });
    }
    return lower.add(.{
        .data = .{ .field_val = .{ .base = base, .index = at } },
        .val = .{ .ty = ft },
        .token = lower.tree.firstToken(node),
        .last = access.name_token,
    });
}

/// The field's position in `owner`, reporting when there is no such field.
fn resolveField(lower: *Lower, owner: Type.Index, name_token: Token) Allocator.Error!?u32 {
    const text = lower.tree.tokenSlice(name_token);
    const wanted = try lower.types.internString(lower.gpa, text);
    if (lower.types.findField(owner, wanted)) |at| return at;
    _ = try lower.fail(.{
        .tag = .no_such_field,
        .token = name_token,
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
    return null;
}

fn call(lower: *Lower, node: Ast.Node.Index, it: Ast.View.Call) Allocator.Error!Ref {
    const token = lower.mainToken(node);
    const span: Span = .{ lower.tree.firstToken(node), lower.tree.lastToken(node) };

    const callee = switch (lower.tree.viewOf(it.callee)) {
        // Arena's operations are builtins, so the receiver decides before any field lookup.
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
    // What the source wrote, not what produced the value.
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
    const top = lower.scratch.items.len;
    defer lower.scratch.shrinkRetainingCapacity(top);

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
        try lower.scratch.append(lower.gpa, value);
    }

    if (it.args.len != signature.params.len) try lower.report(try lower.arityEntry(
        span,
        callee_name,
        signature.params.len,
        it.args.len,
        try lower.declaredMark(it.callee, callee_ty),
    ));

    return lower.add(.{
        .data = .{ .call = .{
            .callee = callee,
            .args = try lower.b.argRange(lower.scratch.items[top..]),
        } },
        .val = .{ .ty = signature.return_type },
        .token = span[0],
        .last = span[1],
    });
}

fn arityEntry(
    lower: *Lower,
    span: Span,
    name_text: []const u8,
    wanted: usize,
    got: usize,
    marks: []const Diagnostic.Mark,
) Allocator.Error!Diagnostic.Entry {
    return .{
        .tag = .wrong_arg_count,
        .token = span[0],
        .last = span[1],
        .message = try lower.print("'{s}' takes {d} argument{s}, but {d} {s} given", .{
            name_text,
            wanted,
            if (wanted == 1) "" else "s",
            got,
            if (got == 1) "was" else "were",
        }),
        .text = try lower.print("{d} given here", .{got}),
        .marks = marks,
    };
}

fn undefinedName(token: Token) Diagnostic.Entry {
    return .{ .tag = .undefined_name, .token = token, .text = "not found in this scope" };
}

fn calleeName(lower: *Lower, node: Ast.Node.Index) ?[]const u8 {
    return switch (lower.tree.viewOf(node)) {
        .ident => |token| lower.tree.tokenSlice(token),
        .field_access => |access| lower.tree.tokenSlice(access.name_token),
        else => null,
    };
}

/// Where the callee was declared, so a bad call shows both ends of itself.
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
    else if (lower.sema.namespace.find(text)) |index|
        lower.sema.namespace.decl(index).name_token
    else
        return &.{};

    return lower.mark(at, try lower.print("'{s}' is declared here, as '{s}'", .{
        text, try lower.typeName(ty),
    }));
}

fn paramSite(lower: *Lower, callee_node: Ast.Node.Index, at: usize) ?Token {
    const token = switch (lower.tree.viewOf(callee_node)) {
        .ident => |t| t,
        else => return null,
    };
    const index = lower.sema.namespace.find(lower.tree.tokenSlice(token)) orelse return null;
    const function = switch (lower.tree.viewOf(lower.sema.namespace.decl(index).node)) {
        .fn_decl => |f| f,
        else => return null,
    };
    if (at >= function.params.len) return null;
    return switch (lower.tree.viewOf(function.params[at])) {
        .param => |p| p.name_token,
        else => null,
    };
}

/// Whether `ref` names the `Arena` type itself, as `Arena.init()` does.
fn isArenaType(lower: *const Lower, ref: Ref) bool {
    return lower.b.dataOf(ref) == .decl and lower.b.valOf(ref).asType() == .Arena;
}

/// `Arena`'s operations
const Method = enum { init, child, create, copy, reset, destroy };

fn arenaMethod(
    lower: *Lower,
    node: Ast.Node.Index,
    receiver: Ref,
    name_token: Token,
    args: []const Ast.Node.Index,
) Allocator.Error!Ref {
    const span: Span = .{ lower.tree.firstToken(node), lower.tree.lastToken(node) };
    const text = lower.tree.tokenSlice(name_token);
    const method = std.meta.stringToEnum(Method, text) orelse return lower.fail(.{
        .tag = .no_such_field,
        .token = name_token,
        .message = try lower.print("'Arena' has no operation named '{s}'", .{text}),
    });

    const wanted: usize = switch (method) {
        .create, .copy => 1,
        else => 0,
    };
    if (args.len != wanted) {
        return lower.fail(try lower.arityEntry(span, text, wanted, args.len, &.{}));
    }

    switch (method) {
        .init => return lower.add(.{
            .data = .arena_init,
            .val = .{ .ty = .Arena },
            .token = span[0],
            .last = span[1],
        }),
        .child => return lower.add(.{
            .data = .{ .arena_child = receiver },
            .val = .{ .ty = .Arena },
            .token = span[0],
            .last = span[1],
        }),
        .reset => return lower.add(.{
            .data = .{ .arena_reset = receiver },
            .val = .{ .ty = .void },
            .token = span[0],
            .last = span[1],
        }),
        .destroy => return lower.add(.{
            .data = .{ .arena_destroy = receiver },
            .val = .{ .ty = .void },
            .token = span[0],
            .last = span[1],
        }),
        .create => {
            const of = try lower.sema.evalTypeExpr(args[0]);
            const ty = if (of == .poisoned)
                Type.Index.poisoned
            else
                try lower.types.pointerType(lower.gpa, of, true);
            return lower.add(.{
                .data = .{ .arena_create = receiver },
                .val = .{ .ty = ty },
                .token = span[0],
                .last = span[1],
            });
        },
        .copy => {
            const value = try lower.expr(args[0]);
            const ty = lower.typeOf(value);
            // A copy would relabel the pointer without moving what it reaches.
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
            return lower.add(.{
                .data = .{ .arena_copy = .{ .arena = receiver, .value = value } },
                .val = .{ .ty = ty },
                .token = span[0],
                .last = span[1],
            });
        },
    }
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

/// `fields 'value' and 'next'`, when a diagnostic has to say what a type does have.
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
