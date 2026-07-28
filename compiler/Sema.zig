//! Resolves declarations, and hosts the checks every pass shares. `expect` is the one
//! door a value walks through to become another type, and `binOp` with `unOp` say what
//! each operator means. `Lower` calls both, so every site is judged by the same rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Namespace = @import("Namespace.zig");
const Type = @import("Type.zig");
const Value = @import("Value.zig");

const Sema = @This();
const Decl = Namespace.Decl;
const Token = Ast.TokenIndex;

gpa: Allocator,
types: *Type,
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
    return sema.types.spell(ty, sema.diagnostics.allocator());
}

fn report(sema: *Sema, tag: Diagnostic.Tag, token: Token) Allocator.Error!void {
    try sema.diagnostics.add(.{ .tag = tag, .token = token });
}

/// Analysis never stops at the first mistake, so what has no answer becomes poison.
fn fail(sema: *Sema, tag: Diagnostic.Tag, token: Token) Allocator.Error!Type.Index {
    try sema.report(tag, token);
    return .poisoned;
}

// Declarations

pub fn resolveDeclarations(sema: *Sema) Allocator.Error!void {
    for (sema.namespace.all()) |*decl| try sema.resolveDecl(decl);
    sema.diagnostics.sortBySource();
}

/// Reentrant, so `in_progress` means the declaration needs itself.
pub fn resolveDecl(sema: *Sema, decl: *Decl) Allocator.Error!void {
    switch (decl.state) {
        .resolved => return,
        .in_progress => {
            try sema.report(.depends_on_itself, decl.name_token);
            decl.value = .poisoned;
            decl.state = .resolved;
            return;
        },
        .unresolved => {},
    }

    decl.state = .in_progress;
    switch (sema.tree.viewOf(decl.node)) {
        .var_decl => |binding| try sema.resolveBinding(decl, binding),
        .fn_decl => |function| decl.value = .{ .ty = try sema.evalFuncType(function) },
        .use_decl => sema.resolveImport(decl),
        else => unreachable, // `Namespace.collect` binds only these three
    }
    decl.state = .resolved;
}

fn resolveBinding(sema: *Sema, decl: *Decl, binding: Ast.View.VarDecl) Allocator.Error!void {
    // A struct is declared before its fields resolve, so they can point back at it.
    var value: Value = switch (sema.tree.viewOf(binding.init_expr)) {
        .struct_type => |fields| .ofType(try sema.evalStructType(fields, decl)),
        else => try sema.evalComptime(binding.init_expr),
    };

    // The written type wins, once the value is checked to fit it.
    if (binding.type_expr.unwrap()) |annotation| {
        const declared = try sema.evalTypeExpr(annotation);
        const fits = try sema.expect(declared, value, binding.init_expr, .{ .annotation = .{
            .name = decl.name_token,
            .site = sema.tree.nodeMainToken(annotation),
        } });
        value = .{ .ty = declared, .known = if (fits) value.known else .runtime };
    }

    decl.value = value;
}

fn resolveImport(sema: *Sema, decl: *Decl) void {
    const builtin = Type.builtinNamed(sema.tree.tokenSlice(decl.name_token)) orelse
        return;
    decl.value = .ofType(builtin);
}

// Comptime evaluation

/// Evaluates an expression no running program computes, meaning a container
/// initializer or a type position. Types are values, so one walk serves both.
pub fn evalComptime(sema: *Sema, node: Ast.Node.Index) Allocator.Error!Value {
    switch (sema.tree.viewOf(node)) {
        .number_literal => |token| {
            return Value.parse(sema.tree.tokenSlice(token)) catch |err| {
                try sema.report(switch (err) {
                    error.InvalidDigit => .invalid_digit,
                    error.TooLarge => .literal_too_large,
                }, token);
                return .poisoned;
            };
        },
        .str_literal => return .{ .ty = .str },
        .bool_literal => |it| return .{ .ty = .bool, .known = .{ .bool = it.value } },
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
            return .ofType(try sema.types.pointerType(sema.gpa, pointee, pointer.is_mutable));
        },
        .struct_type => |fields| return .ofType(try sema.evalStructType(fields, null)),
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
fn evalName(sema: *Sema, token: Token) Allocator.Error!Value {
    const name = sema.tree.tokenSlice(token);
    if (Type.builtinNamed(name)) |builtin| return .ofType(builtin); // nothing can rebind `i64`

    const decl = sema.namespace.find(name) orelse {
        try sema.report(.undefined_name, token);
        return .poisoned;
    };
    try sema.resolveDecl(decl);
    return decl.value;
}

pub fn evalTypeExpr(sema: *Sema, node: Ast.Node.Index) Allocator.Error!Type.Index {
    const value = try sema.evalComptime(node);
    if (value.ty == .poisoned) return .poisoned;
    return value.asType() orelse {
        try sema.diagnostics.add(.{
            .tag = .not_a_type,
            .token = sema.tree.firstToken(node),
            .last = sema.tree.lastToken(node),
            .message = try sema.diagnostics.print("this is '{s}', not a type", .{
                try sema.typeName(value.ty),
            }),
        });
        return .poisoned;
    };
}

// The door

/// What a value was checked against, which decides how a refusal reads.
pub const Expect = union(enum) {
    /// An annotated binding. `site` is where the type was written.
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
/// the words of `ctx`, and returns whether it fits.
pub fn expect(
    sema: *Sema,
    into: Type.Index,
    value: Value,
    node: Ast.Node.Index,
    ctx: Expect,
) Allocator.Error!bool {
    if (into == .poisoned or value.ty == .poisoned) return true;
    sema.types.coerce(value, into) catch |refusal| {
        switch (refusal) {
            error.OutOfRange => try sema.reportRange(node, value.known.int, into, ctx),
            error.WrongType => try sema.reportMismatch(into, value, node, ctx),
        }
        return false;
    };
    return true;
}

fn reportMismatch(
    sema: *Sema,
    into: Type.Index,
    value: Value,
    node: Ast.Node.Index,
    ctx: Expect,
) Allocator.Error!void {
    const d = sema.diagnostics;
    const wanted = try sema.typeName(into);
    const got = try sema.typeName(value.ty);
    const returns_nothing = ctx == .returned and value.ty == .void;

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
        // A known value tells more than its type. `this is 3.5` explains what
        // `this is 'comptime_float'` only classifies.
        .text = if (returns_nothing)
            "nothing is returned here"
        else switch (value.known) {
            .int => |x| try d.print("this is {d}", .{x}),
            .float => |x| try d.print("this is {d}", .{x}),
            else => try d.print("this is '{s}'", .{got}),
        },
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

/// Types and folds one binary operation. The operands settle on a peer type, each side
/// has to fit it, and what folding proves is reported here.
pub fn binOp(
    sema: *Sema,
    node: Ast.Node.Index,
    it: Ast.View.Binary,
    lhs: Value,
    rhs: Value,
) Allocator.Error!Value {
    const in_op: Expect = .{ .operand = .{ .op = it.op_token } };
    switch (it.op) {
        // Checked side by side, so each wrong operand is its own report.
        .bool_and, .bool_or => {
            _ = try sema.expect(.bool, lhs, it.lhs, in_op);
            _ = try sema.expect(.bool, rhs, it.rhs, in_op);
            return .{ .ty = .bool, .known = Value.fold(it.op, lhs.known, rhs.known) catch .runtime };
        },
        else => {},
    }

    const comparing = switch (it.op) {
        .equal, .not_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal => true,
        else => false,
    };

    const resolved = sema.types.peer(lhs.ty, rhs.ty) orelse {
        try sema.reportUncombinable(it, lhs.ty, rhs.ty);
        return .poisoned;
    };
    if (resolved == .poisoned) return .poisoned;

    const accepted = switch (it.op) {
        .equal, .not_equal => sema.types.canEqual(resolved),
        else => Type.isNumber(resolved),
    };
    if (!accepted) {
        try sema.reportOperandKind(node, it, resolved, comparing);
        return if (comparing) .{ .ty = .bool } else .poisoned;
    }

    const lhs_fits = try sema.expect(resolved, lhs, it.lhs, in_op);
    const rhs_fits = try sema.expect(resolved, rhs, it.rhs, in_op);
    // An operand that does not fit was reported, so folding would repeat it.
    if (!lhs_fits or !rhs_fits) return .{ .ty = if (comparing) .bool else resolved };

    const known = Value.fold(it.op, lhs.known, rhs.known) catch |err| {
        try sema.reportFold(err, it.op_token);
        return .poisoned;
    };
    if (comparing) return .{ .ty = .bool, .known = known };

    // What the fold proves is judged where the operands settled.
    if (known == .int) if (Type.intRange(resolved)) |range| {
        if (known.int < range.min or known.int > range.max) {
            try sema.reportFoldRange(node, it, known.int, resolved, lhs, rhs);
            return .{ .ty = resolved };
        }
    };
    return .{ .ty = resolved, .known = known };
}

pub fn unOp(
    sema: *Sema,
    node: Ast.Node.Index,
    it: Ast.View.Unary,
    operand: Value,
) Allocator.Error!Value {
    switch (it.op) {
        .bool_not => {
            _ = try sema.expect(.bool, operand, it.operand, .{ .operand = .{ .op = it.op_token } });
            return .{ .ty = .bool, .known = Value.boolNot(operand.known) };
        },
        .negate => {
            if (operand.ty == .poisoned) return .poisoned;
            if (!Type.isNumber(operand.ty) or Type.isUnsignedInt(operand.ty)) {
                try sema.reportNotNegatable(node, operand.ty);
                return .poisoned;
            }
            const known = Value.negate(operand.known) catch {
                try sema.reportFold(error.Overflow, it.op_token);
                return .poisoned;
            };
            return .{ .ty = operand.ty, .known = known };
        },
    }
}

fn reportNotNegatable(sema: *Sema, node: Ast.Node.Index, ty: Type.Index) Allocator.Error!void {
    try sema.diagnostics.add(.{
        .tag = .type_mismatch,
        .token = sema.tree.firstToken(node),
        .last = sema.tree.lastToken(node),
        .message = try sema.diagnostics.print(
            "'-' works on signed numbers, but this is '{s}'",
            .{try sema.typeName(ty)},
        ),
    });
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
    lhs: Value,
    rhs: Value,
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

fn reportFold(sema: *Sema, err: Value.FoldError, token: Token) Allocator.Error!void {
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
            try sema.report(.redeclared, declared.name_token);
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

/// Nominal, so the declaration site makes it distinct rather than the fields. `owner`
/// gives the name, and lets a field point back before the fields resolve.
fn evalStructType(
    sema: *Sema,
    fields: []const Ast.Node.Index,
    owner: ?*Decl,
) Allocator.Error!Type.Index {
    const name = if (owner) |decl|
        try sema.types.internString(sema.gpa, sema.tree.tokenSlice(decl.name_token))
    else
        .empty;
    const ty = try sema.types.declareStruct(sema.gpa, name);

    // Finished before a field is looked at, so a field can point back at it.
    if (owner) |decl| {
        decl.value = .ofType(ty);
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

    var names: std.ArrayList(Type.String) = .empty;
    defer names.deinit(sema.gpa);

    for (0..fields.len) |at| {
        const field = (try sema.typedNameIn(fields, at)) orelse continue;

        var field_ty = try sema.evalTypeExpr(field.type_expr);
        // A field held by value needs a size where a pointer to one does not.
        if (!sema.types.isDefined(field_ty))
            field_ty = try sema.fail(.depends_on_itself, blame orelse field.name_token);

        try sema.scratch.append(sema.gpa, field_ty);
        try names.append(
            sema.gpa,
            try sema.types.internString(sema.gpa, sema.tree.tokenSlice(field.name_token)),
        );
    }

    try sema.types.defineStruct(sema.gpa, ty, names.items, sema.scratch.items[base..]);
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

    return sema.types.funcType(sema.gpa, sema.scratch.items[base..], return_type);
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
