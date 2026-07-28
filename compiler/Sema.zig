//! Resolves declarations, and hosts the checks every pass shares: `expect` is the one
//! door a value walks through to become another type, and `binOp`/`unOp` are the one
//! statement of what each operator means. `Lower` calls both, so a function body and a
//! container declaration are judged by the same rules and report in the same words.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Comptime = @import("Comptime.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Namespace = @import("Namespace.zig");
const Type = @import("Type.zig");

const Sema = @This();
const Decl = Namespace.Decl;
const Token = Ast.TokenIndex;
const Value = Comptime.Value;
const TypedValue = Comptime.TypedValue;

gpa: Allocator,
pool: *InternPool,
/// Borrowed, must outlive this.
tree: *const Ast,
namespace: *Namespace,
diagnostics: *Diagnostic.List,
/// Every type list under construction. Each user shrinks back to its entry length.
scratch: std.ArrayList(Type.Index) = .empty,

pub fn deinit(sema: *Sema) void {
    sema.scratch.deinit(sema.gpa);
    sema.* = undefined;
}

pub fn typeName(sema: *Sema, ty: Type.Index) Allocator.Error![]const u8 {
    return Type.spell(sema.pool, ty, sema.diagnostics.allocator());
}

/// Analysis never stops at the first mistake, so what has no answer becomes poison.
fn fail(sema: *Sema, tag: Diagnostic.Tag, token: Token) Allocator.Error!Type.Index {
    try sema.diagnostics.add(.{ .tag = tag, .token = token });
    return .poisoned;
}

// Declarations

pub fn resolveDeclarations(sema: *Sema) Allocator.Error!void {
    for (sema.namespace.all()) |*decl| try sema.resolveDecl(decl);
    sema.diagnostics.sortBySource();
}

/// Reentrant: `in_progress` means the declaration needs itself.
pub fn resolveDecl(sema: *Sema, decl: *Decl) Allocator.Error!void {
    switch (decl.state) {
        .resolved => return,
        .in_progress => {
            decl.ty = try sema.fail(.depends_on_itself, decl.name_token);
            decl.state = .resolved;
            return;
        },
        .unresolved => {},
    }

    decl.state = .in_progress;
    switch (sema.tree.viewOf(decl.node)) {
        .var_decl => |binding| try sema.resolveBinding(decl, binding),
        .fn_decl => |function| decl.ty = try sema.evalFuncType(function),
        .use_decl => sema.resolveImport(decl),
        else => unreachable, // `Namespace.collect` binds only these three
    }
    decl.state = .resolved;
}

fn resolveBinding(sema: *Sema, decl: *Decl, binding: Ast.View.VarDecl) Allocator.Error!void {
    // A struct is declared before its fields resolve, so they can point back at it.
    var tv: TypedValue = switch (sema.tree.viewOf(binding.init_expr)) {
        .struct_type => |fields| .{
            .ty = .type,
            .val = .{ .type = try sema.evalStructType(fields, decl) },
        },
        else => try sema.evalComptime(binding.init_expr),
    };

    // The written type wins, once the value is checked to fit it.
    if (binding.type_expr.unwrap()) |annotation| {
        const declared = try sema.evalTypeExpr(annotation);
        const fits = try sema.expect(declared, tv, binding.init_expr, .{ .annotation = .{
            .name = decl.name_token,
            .site = sema.tree.nodeMainToken(annotation),
        } });
        tv = .{ .ty = declared, .val = if (fits) tv.val else .unknown };
    }

    decl.ty = tv.ty;
    decl.val = tv.val;
}

fn resolveImport(sema: *Sema, decl: *Decl) void {
    const builtin = InternPool.builtinNamed(sema.tree.tokenSlice(decl.name_token)) orelse
        return;
    decl.setType(builtin);
}

// Comptime evaluation

/// Evaluates an expression no running program computes: a container initializer or a
/// type position. Types are values here, which is why one walk serves both.
pub fn evalComptime(sema: *Sema, node: Ast.Node.Index) Allocator.Error!TypedValue {
    switch (sema.tree.viewOf(node)) {
        .number_literal => |token| {
            const val = Comptime.parse(sema.tree.tokenSlice(token)) catch |err| {
                _ = try sema.fail(switch (err) {
                    error.InvalidDigit => .invalid_digit,
                    error.TooLarge => .literal_too_large,
                }, token);
                return .poisoned;
            };
            return .{ .ty = Comptime.typeOf(val), .val = val };
        },
        .str_literal => return .{ .ty = .str },
        .bool_literal => |it| return .{ .ty = .bool, .val = .{ .bool = it.value } },
        .grouped => |inner| return sema.evalComptime(inner),
        .ident => |token| return sema.evalName(token),
        .unary => |it| return sema.unOp(node, it, try sema.evalComptime(it.operand)),
        .binary => |it| {
            const lhs = try sema.evalComptime(it.lhs);
            const rhs = try sema.evalComptime(it.rhs);
            return sema.binOp(node, it, lhs, rhs);
        },
        .pointer_type => |pointer| {
            // Identity is enough, which is what lets two structs refer to each other.
            const pointee = try sema.evalTypeExpr(pointer.child);
            if (pointee == .poisoned) return .poisoned;
            return .{ .ty = .type, .val = .{ .type = try sema.pool.intern(sema.gpa, .{
                .pointer = .{ .pointee = pointee, .is_mutable = pointer.is_mutable },
            }) } };
        },
        .struct_type => |fields| return .{
            .ty = .type,
            .val = .{ .type = try sema.evalStructType(fields, null) },
        },
        .err => return .poisoned,
        else => {
            try sema.diagnostics.add(.{
                .tag = .unsupported_value,
                .token = sema.tree.firstToken(node),
                .last = sema.tree.lastToken(node),
            });
            return .poisoned;
        },
    }
}

/// The edge that makes resolution order independent.
fn evalName(sema: *Sema, token: Token) Allocator.Error!TypedValue {
    const name = sema.tree.tokenSlice(token);
    if (InternPool.builtinNamed(name)) |builtin| // nothing can rebind `i64`
        return .{ .ty = .type, .val = .{ .type = builtin } };

    const decl = sema.namespace.find(name) orelse {
        _ = try sema.fail(.undefined_name, token);
        return .poisoned;
    };
    try sema.resolveDecl(decl);
    return .{ .ty = decl.ty, .val = decl.val };
}

pub fn evalTypeExpr(sema: *Sema, node: Ast.Node.Index) Allocator.Error!Type.Index {
    const tv = try sema.evalComptime(node);
    if (tv.ty == .poisoned) return .poisoned;
    if (tv.ty != .type or tv.val != .type) {
        try sema.diagnostics.add(.{
            .tag = .not_a_type,
            .token = sema.tree.firstToken(node),
            .last = sema.tree.lastToken(node),
            .message = try sema.diagnostics.print("this is '{s}', not a type", .{
                try sema.typeName(tv.ty),
            }),
        });
        return .poisoned;
    }
    return tv.val.type;
}

// The door

/// What a value was checked against, which decides how a refusal reads.
pub const Expect = union(enum) {
    /// `let name: T = value`. `site` is the annotation.
    annotation: struct { name: Token, site: Token },
    /// `return value`. `site` is the return type in the signature, when written.
    returned: struct { fn_name: Token, site: ?Token },
    /// One argument of a call. `site` is the parameter's declaration, when known.
    argument: struct { position: usize, callee: []const u8, site: ?Token },
    /// `name = value`. `site` is where the name was declared.
    assigned: struct { name: Token, site: Token },
    /// `owner.name = value`.
    field_store: struct { name: Token },
    /// An operand of `op`.
    operand: struct { op: Token },
};

/// The one place a value meets the type something needs it to be. Reports a refusal in
/// the words of `ctx`; true means it fits.
pub fn expect(
    sema: *Sema,
    into: Type.Index,
    tv: TypedValue,
    node: Ast.Node.Index,
    ctx: Expect,
) Allocator.Error!bool {
    if (into == .poisoned or tv.ty == .poisoned) return true;
    Type.coerce(sema.pool, tv.ty, into, tv.val) catch |refusal| {
        switch (refusal) {
            error.OutOfRange => try sema.reportRange(node, tv.val.int, into, ctx),
            error.WrongType => try sema.reportMismatch(into, tv.ty, node, ctx),
        }
        return false;
    };
    return true;
}

fn reportMismatch(
    sema: *Sema,
    into: Type.Index,
    from: Type.Index,
    node: Ast.Node.Index,
    ctx: Expect,
) Allocator.Error!void {
    const d = sema.diagnostics;
    const wanted = try sema.typeName(into);
    const got = try sema.typeName(from);
    const returns_nothing = ctx == .returned and from == .void;

    try d.add(.{
        .tag = .type_mismatch,
        .token = sema.tree.firstToken(node),
        .last = sema.tree.lastToken(node),
        .message = switch (ctx) {
            .annotation => |it| try d.print("'{s}' is declared '{s}', but its value is '{s}'", .{
                sema.tree.tokenSlice(it.name), wanted, got,
            }),
            .returned => |it| if (returns_nothing)
                try d.print("'{s}' returns '{s}', but this 'return' has no value", .{
                    sema.tree.tokenSlice(it.fn_name), wanted,
                })
            else
                try d.print("'{s}' returns '{s}', but this is '{s}'", .{
                    sema.tree.tokenSlice(it.fn_name), wanted, got,
                }),
            .argument => |it| try d.print("argument {d} of '{s}' is '{s}', but this is '{s}'", .{
                it.position + 1, it.callee, wanted, got,
            }),
            .assigned => |it| try d.print("'{s}' holds '{s}', but this is '{s}'", .{
                sema.tree.tokenSlice(it.name), wanted, got,
            }),
            .field_store => |it| try d.print("field '{s}' is '{s}', but this is '{s}'", .{
                sema.tree.tokenSlice(it.name), wanted, got,
            }),
            .operand => |it| try d.print("'{s}' needs '{s}', but this is '{s}'", .{
                sema.tree.tokenSlice(it.op), wanted, got,
            }),
        },
        .text = if (returns_nothing)
            "nothing is returned here"
        else
            try d.print("this is '{s}'", .{got}),
        .marks = try sema.expectMark(ctx, into),
    });
}

/// Where the expected type came from, so a mismatch points at both halves of itself.
fn expectMark(sema: *Sema, ctx: Expect, into: Type.Index) Allocator.Error![]const Diagnostic.Mark {
    const d = sema.diagnostics;
    const wanted = try sema.typeName(into);
    return switch (ctx) {
        .annotation => |it| d.mark(it.site, try d.print("declared '{s}' here", .{wanted})),
        .returned => |it| if (it.site) |site|
            d.mark(site, try d.print("declared to return '{s}'", .{wanted}))
        else
            &.{},
        .argument => |it| if (it.site) |site|
            d.mark(site, try d.print("'{s}' is declared '{s}'", .{
                sema.tree.tokenSlice(site), wanted,
            }))
        else
            &.{},
        .assigned => |it| d.mark(it.site, try d.print("'{s}' was declared here", .{
            sema.tree.tokenSlice(it.name),
        })),
        .field_store => |it| d.mark(it.name, try d.print("'{s}' is '{s}'", .{
            sema.tree.tokenSlice(it.name), wanted,
        })),
        .operand => &.{},
    };
}

/// A known value that no amount of agreement in kind can save.
fn reportRange(
    sema: *Sema,
    node: Ast.Node.Index,
    value: i128,
    into: Type.Index,
    ctx: Expect,
) Allocator.Error!void {
    const d = sema.diagnostics;
    const name = try sema.typeName(into);
    const holds = if (Type.intRange(into)) |range|
        try d.print("'{s}' holds {d} to {d}", .{ name, range.min, range.max })
    else
        try d.print("'{s}' holds nothing negative", .{name});

    try d.add(.{
        .tag = .out_of_range,
        .token = sema.tree.firstToken(node),
        .last = sema.tree.lastToken(node),
        .message = try d.print("{d} does not fit in '{s}'", .{ value, name }),
        .text = try d.print("this is {d}", .{value}),
        .marks = try sema.expectMark(ctx, into),
        .notes = try d.notes(&.{.{ .kind = .note, .text = holds }}),
    });
}

// Operators

/// Types and folds one binary operation: the operands settle on a peer type, each side
/// has to fit it, and known values fold, with everything folding proves reported here.
pub fn binOp(
    sema: *Sema,
    node: Ast.Node.Index,
    it: Ast.View.Binary,
    lhs: TypedValue,
    rhs: TypedValue,
) Allocator.Error!TypedValue {
    const in_op: Expect = .{ .operand = .{ .op = it.op_token } };
    switch (it.op) {
        // Checked side by side, so each wrong operand is its own report.
        .bool_and, .bool_or => {
            _ = try sema.expect(.bool, lhs, it.lhs, in_op);
            _ = try sema.expect(.bool, rhs, it.rhs, in_op);
            return .{ .ty = .bool, .val = Comptime.fold(it.op, lhs.val, rhs.val) catch .unknown };
        },
        else => {},
    }

    const comparing = switch (it.op) {
        .equal, .not_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal => true,
        else => false,
    };

    const resolved = Type.peer(sema.pool, lhs.ty, rhs.ty) orelse {
        try sema.reportUncombinable(it, lhs.ty, rhs.ty);
        return .poisoned;
    };
    if (resolved == .poisoned) return .poisoned;

    const accepted = switch (it.op) {
        .equal, .not_equal => Type.canEqual(sema.pool, resolved),
        else => Type.isNumber(resolved),
    };
    if (!accepted) {
        try sema.reportOperandKind(node, it, resolved, comparing);
        return if (comparing) .{ .ty = .bool } else .poisoned;
    }

    const lhs_fits = try sema.expect(resolved, lhs, it.lhs, in_op);
    const rhs_fits = try sema.expect(resolved, rhs, it.rhs, in_op);
    // An operand that does not fit was reported; folding it would only repeat that.
    if (!lhs_fits or !rhs_fits) return .{ .ty = if (comparing) .bool else resolved };

    const val = Comptime.fold(it.op, lhs.val, rhs.val) catch |err| {
        try sema.reportFold(err, it.op_token);
        return .poisoned;
    };
    if (comparing) return .{ .ty = .bool, .val = val };

    // What the fold proves is judged where the operands settled.
    if (val == .int) if (Type.intRange(resolved)) |range| {
        if (val.int < range.min or val.int > range.max) {
            try sema.reportFoldRange(node, it, val.int, resolved, lhs, rhs);
            return .{ .ty = resolved };
        }
    };
    return .{ .ty = resolved, .val = val };
}

pub fn unOp(
    sema: *Sema,
    node: Ast.Node.Index,
    it: Ast.View.Unary,
    operand: TypedValue,
) Allocator.Error!TypedValue {
    switch (it.op) {
        .bool_not => {
            _ = try sema.expect(.bool, operand, it.operand, .{ .operand = .{ .op = it.op_token } });
            return .{ .ty = .bool, .val = Comptime.boolNot(operand.val) };
        },
        .negate => {
            if (operand.ty == .poisoned) return .poisoned;
            if (!Type.isNumber(operand.ty) or Type.isUnsignedInt(operand.ty)) {
                try sema.diagnostics.add(.{
                    .tag = .type_mismatch,
                    .token = sema.tree.firstToken(node),
                    .last = sema.tree.lastToken(node),
                    .message = try sema.diagnostics.print(
                        "'-' works on signed numbers, but this is '{s}'",
                        .{try sema.typeName(operand.ty)},
                    ),
                });
                return .poisoned;
            }
            const val = Comptime.negate(operand.val) catch {
                try sema.reportFold(error.Overflow, it.op_token);
                return .poisoned;
            };
            return .{ .ty = operand.ty, .val = val };
        },
    }
}

fn reportUncombinable(
    sema: *Sema,
    it: Ast.View.Binary,
    a: Type.Index,
    b: Type.Index,
) Allocator.Error!void {
    const d = sema.diagnostics;
    try d.add(.{
        .tag = .type_mismatch,
        .token = it.op_token,
        .message = try d.print("'{s}' cannot combine '{s}' and '{s}'", .{
            sema.tree.tokenSlice(it.op_token), try sema.typeName(a), try sema.typeName(b),
        }),
        .marks = try d.marks(&.{
            .{
                .token = sema.tree.firstToken(it.lhs),
                .last = sema.tree.lastToken(it.lhs),
                .text = try d.print("this is '{s}'", .{try sema.typeName(a)}),
            },
            .{
                .token = sema.tree.firstToken(it.rhs),
                .last = sema.tree.lastToken(it.rhs),
                .text = try d.print("this is '{s}'", .{try sema.typeName(b)}),
            },
        }),
    });
}

fn reportOperandKind(
    sema: *Sema,
    node: Ast.Node.Index,
    it: Ast.View.Binary,
    resolved: Type.Index,
    comparing: bool,
) Allocator.Error!void {
    const d = sema.diagnostics;
    const op = sema.tree.tokenSlice(it.op_token);
    const name = try sema.typeName(resolved);
    try d.add(.{
        .tag = .type_mismatch,
        .token = sema.tree.firstToken(node),
        .last = sema.tree.lastToken(node),
        .message = if (comparing)
            try d.print("'{s}' cannot compare '{s}' values yet", .{ op, name })
        else
            try d.print("'{s}' works on numbers, but '{s}' is not one", .{ op, name }),
    });
}

/// An overflowed fold points at where the operands settled, since that is the type that
/// refused the result.
fn reportFoldRange(
    sema: *Sema,
    node: Ast.Node.Index,
    it: Ast.View.Binary,
    value: i128,
    resolved: Type.Index,
    lhs: TypedValue,
    rhs: TypedValue,
) Allocator.Error!void {
    const source = if (lhs.ty == resolved) it.lhs else if (rhs.ty == resolved) it.rhs else null;
    const marks: []const Diagnostic.Mark = if (source) |side| try sema.diagnostics.marks(&.{.{
        .token = sema.tree.firstToken(side),
        .last = sema.tree.lastToken(side),
        .text = try sema.diagnostics.print("'{s}' because of this", .{try sema.typeName(resolved)}),
    }}) else &.{};

    const range = Type.intRange(resolved) orelse return;
    const d = sema.diagnostics;
    try d.add(.{
        .tag = .out_of_range,
        .token = sema.tree.firstToken(node),
        .last = sema.tree.lastToken(node),
        .message = try d.print("this comes to {d}, which does not fit in '{s}'", .{
            value, try sema.typeName(resolved),
        }),
        .text = try d.print("this is {d}", .{value}),
        .marks = marks,
        .notes = try d.notes(&.{.{
            .kind = .note,
            .text = try d.print("'{s}' holds {d} to {d}", .{
                try sema.typeName(resolved), range.min, range.max,
            }),
        }}),
    });
}

fn reportFold(sema: *Sema, err: Comptime.FoldError, token: Token) Allocator.Error!void {
    switch (err) {
        error.DivisionByZero => try sema.diagnostics.add(.{
            .tag = .division_by_zero,
            .token = token,
            .text = "the divisor is 0",
        }),
        error.Overflow => try sema.diagnostics.add(.{
            .tag = .comptime_overflow,
            .token = token,
            .notes = try sema.diagnostics.notes(&.{.{
                .kind = .note,
                .text = "comptime integers hold up to 128 bits",
            }}),
        }),
    }
}

// Composite types

/// Null when there is nothing to declare, the parser rejected it, or an earlier sibling
/// took the name. A `param` and a `field` are the same shape, so one walk serves both.
fn typedNameIn(
    sema: *Sema,
    nodes: []const Ast.Node.Index,
    at: usize,
) Allocator.Error!?Ast.View.TypedName {
    const declared = sema.typedNameOf(nodes[at]) orelse return null;
    const name = sema.tree.tokenSlice(declared.name_token);
    for (nodes[0..at]) |earlier| {
        const seen = sema.typedNameOf(earlier) orelse continue;
        if (std.mem.eql(u8, sema.tree.tokenSlice(seen.name_token), name)) {
            _ = try sema.fail(.redeclared, declared.name_token);
            return null;
        }
    }
    return declared;
}

fn typedNameOf(sema: *Sema, node: Ast.Node.Index) ?Ast.View.TypedName {
    return switch (sema.tree.viewOf(node)) {
        .param, .field => |declared| declared,
        else => null,
    };
}

/// Nominal: the declaration site makes it distinct, never the fields. `owner` is where
/// the name comes from, and what lets a field point back at it before the fields resolve.
fn evalStructType(
    sema: *Sema,
    fields: []const Ast.Node.Index,
    owner: ?*Decl,
) Allocator.Error!Type.Index {
    const name = if (owner) |decl|
        try sema.pool.internString(sema.gpa, sema.tree.tokenSlice(decl.name_token))
    else
        .empty;
    const ty = try sema.pool.declareStruct(sema.gpa, name);

    // Finished before a field is looked at, so `next: *Node` finds a `Node`.
    if (owner) |decl| {
        decl.setType(ty);
        decl.state = .resolved;
    }

    try sema.resolveStructFields(ty, fields, if (owner) |decl| decl.name_token else null);
    return ty;
}

/// `blame` is the owning declaration when there is one, since a cycle belongs to the
/// type rather than to whichever field happened to close it.
fn resolveStructFields(
    sema: *Sema,
    ty: Type.Index,
    fields: []const Ast.Node.Index,
    blame: ?Token,
) Allocator.Error!void {
    const base = sema.scratch.items.len;
    defer sema.scratch.shrinkRetainingCapacity(base);

    var names: std.ArrayList(InternPool.String) = .empty;
    defer names.deinit(sema.gpa);

    for (0..fields.len) |at| {
        const field = (try sema.typedNameIn(fields, at)) orelse continue;

        var field_ty = try sema.evalTypeExpr(field.type_expr);
        // A field held by value needs a size where a pointer to one does not.
        if (!sema.pool.isDefined(field_ty))
            field_ty = try sema.fail(.depends_on_itself, blame orelse field.name_token);

        try sema.scratch.append(sema.gpa, field_ty);
        try names.append(
            sema.gpa,
            try sema.pool.internString(sema.gpa, sema.tree.tokenSlice(field.name_token)),
        );
    }

    try sema.pool.defineStruct(sema.gpa, ty, names.items, sema.scratch.items[base..]);
}

/// The signature and nothing else, which is what lets a call be checked without the body.
fn evalFuncType(sema: *Sema, function: Ast.View.FnDecl) Allocator.Error!Type.Index {
    const base = sema.scratch.items.len;
    defer sema.scratch.shrinkRetainingCapacity(base);

    var arenas: [2]Ast.View.TypedName = undefined;
    var arena_count: usize = 0;

    for (0..function.params.len) |at| {
        const param = (try sema.typedNameIn(function.params, at)) orelse continue;
        const param_ty = try sema.evalTypeExpr(param.type_expr);
        if (param_ty == .Arena and arena_count < arenas.len) {
            arenas[arena_count] = param;
            arena_count += 1;
        }
        try sema.scratch.append(sema.gpa, param_ty);
    }

    if (arena_count == arenas.len) try sema.tooManyArenas(function, arenas[0], arenas[1]);

    const return_type = if (function.return_type.unwrap()) |node|
        try sema.evalTypeExpr(node)
    else
        .void;

    return sema.pool.intern(sema.gpa, .{ .func = .{
        .params = sema.scratch.items[base..],
        .return_type = return_type,
    } });
}

/// A function allocates its results into exactly one arena, which is what lets a caller
/// know where a result lives without anyone writing a lifetime down.
fn tooManyArenas(
    sema: *Sema,
    function: Ast.View.FnDecl,
    first: Ast.View.TypedName,
    second: Ast.View.TypedName,
) Allocator.Error!void {
    const diagnostics = sema.diagnostics;
    const owner = diagnostics.allocator();
    const name = sema.tree.tokenSlice(second.name_token);

    var marks: std.ArrayList(Diagnostic.Mark) = .empty;
    try marks.append(owner, .{
        .token = first.name_token,
        .last = sema.tree.nodeMainToken(first.type_expr),
        .text = "the first arena parameter",
    });
    if (function.return_type.unwrap()) |node| {
        try marks.append(owner, .{
            .token = sema.tree.nodeMainToken(node),
            .text = "which arena is this in?",
        });
    }

    try diagnostics.add(.{
        .tag = .multiple_arenas,
        .token = second.name_token,
        .last = sema.tree.nodeMainToken(second.type_expr),
        .message = try diagnostics.print(
            "'{s}' takes more than one arena, so its result has no single home",
            .{sema.tree.tokenSlice(function.name_token)},
        ),
        .text = "a second arena parameter",
        .marks = marks.items,
        .notes = try owner.dupe(Diagnostic.Note, &.{
            .{ .kind = .note, .text = "a function allocates its results into exactly one arena. That rule is" ++
                "\nwhat lets a caller know where a result lives without anyone writing a" ++
                "\nlifetime down." },
            .{
                .kind = .help,
                .text = try diagnostics.print(
                    "drop '{s}', and create a child inside the body for temporaries",
                    .{name},
                ),
                .code = try diagnostics.print(
                    "var {s} = {s}.child()",
                    .{ name, sema.tree.tokenSlice(first.name_token) },
                ),
            },
        }),
    });
}
