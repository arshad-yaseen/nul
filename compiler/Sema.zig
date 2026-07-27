const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Namespace = @import("Namespace.zig");
const Type = @import("Type.zig");

const Sema = @This();
const Decl = Namespace.Decl;
const Token = Ast.TokenIndex;

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

/// Analysis never stops at the first mistake, so what has no answer becomes poison.
fn fail(sema: *Sema, tag: Diagnostic.Tag, token: Token) Allocator.Error!Type.Index {
    try sema.diagnostics.add(sema.gpa, .{ .tag = tag, .token = token });
    return .poisoned;
}

// Declarations

pub fn resolveDeclarations(sema: *Sema) Allocator.Error!void {
    for (sema.namespace.all()) |*decl| try sema.resolveDecl(decl);
    sema.diagnostics.sortBySource();
}

/// Reentrant: `in_progress` means the declaration needs itself.
fn resolveDecl(sema: *Sema, decl: *Decl) Allocator.Error!void {
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
    try sema.bindInitializer(decl, binding.init_expr);
    if (binding.type_expr.unwrap()) |annotation| try sema.applyAnnotation(decl, annotation);
}

/// A declaration is either a value, whose type the initializer decides, or a type.
fn bindInitializer(
    sema: *Sema,
    decl: *Decl,
    init_expr: Ast.Node.Index,
) Allocator.Error!void {
    switch (sema.tree.viewOf(init_expr)) {
        .number_literal => |token| decl.ty = try sema.numberLiteralType(token),
        .str_literal => decl.ty = .str,
        .bool_literal => decl.ty = .bool,
        .struct_type => |fields| decl.setType(try sema.evalStructType(fields, decl)),
        else => decl.setType(try sema.evalTypeExpr(init_expr, decl.name_token)),
    }
}

/// The written type wins, once the two are checked to agree.
fn applyAnnotation(
    sema: *Sema,
    decl: *Decl,
    annotation: Ast.Node.Index,
) Allocator.Error!void {
    const declared = try sema.evalTypeExpr(annotation, decl.name_token);
    // `coerce` answers for the type, not the value: whether `300` fits a `u8` needs the
    // literal. Poison on either side already reported.
    if (declared != .poisoned and decl.ty != .poisoned and
        Type.coerce(sema.pool, decl.ty, declared) == null)
    {
        _ = try sema.fail(.type_mismatch, sema.tree.nodeMainToken(annotation));
    }
    decl.ty = declared;
}

/// Builtins are the only part of `std` that exists before the module resolver. Anything
/// else stays bound but unresolved, claiming nothing either way.
fn resolveImport(sema: *Sema, decl: *Decl) void {
    const builtin = InternPool.builtinNamed(sema.tree.tokenSlice(decl.name_token)) orelse
        return;
    decl.setType(builtin);
}

// Type expressions

/// `blame` is where an unevaluable expression is reported, since its own token is often
/// punctuation: for a call it is the `(`.
fn evalTypeExpr(
    sema: *Sema,
    node: Ast.Node.Index,
    blame: Token,
) Allocator.Error!Type.Index {
    switch (sema.tree.viewOf(node)) {
        .ident => |token| return sema.evalNamedType(token),
        .pointer_type => |pointer| {
            // Identity is enough, which is what lets two structs refer to each other.
            const pointee = try sema.evalTypeExpr(pointer.child, blame);
            if (pointee == .poisoned) return .poisoned;
            return sema.pool.intern(sema.gpa, .{ .pointer = .{
                .pointee = pointee,
                .is_mutable = pointer.is_mutable,
            } });
        },
        .struct_type => |fields| return sema.evalStructType(fields, null),
        .grouped => |inner| return sema.evalTypeExpr(inner, blame),
        .err => return .poisoned,
        else => return sema.fail(.unsupported_value, blame),
    }
}

/// The edge that makes resolution order independent.
fn evalNamedType(sema: *Sema, token: Token) Allocator.Error!Type.Index {
    const name = sema.tree.tokenSlice(token);
    if (InternPool.builtinNamed(name)) |builtin| return builtin; // nothing can rebind `i64`

    const decl = sema.namespace.find(name) orelse return sema.fail(.undefined_name, token);
    try sema.resolveDecl(decl);

    if (decl.ty == .poisoned) return .poisoned;
    if (decl.ty != .type) return sema.fail(.not_a_type, token);
    return decl.value;
}

/// The tokenizer accepts more than is valid, so a bad number is caught here.
fn numberLiteralType(sema: *Sema, token: Token) Allocator.Error!Type.Index {
    const number = Type.parseNumber(sema.tree.tokenSlice(token)) catch |err|
        return sema.fail(switch (err) {
            error.InvalidDigit => .invalid_digit,
            error.TooLarge => .literal_too_large,
        }, token);
    return Type.numberType(number);
}

// Composite types

/// Null when there is nothing to bind: the parser rejected it, or an earlier sibling took
/// the name. A `param` and a `field` are the same shape, so one walk serves both.
fn bindingIn(
    sema: *Sema,
    nodes: []const Ast.Node.Index,
    at: usize,
) Allocator.Error!?Ast.View.Binding {
    const binding = sema.bindingOf(nodes[at]) orelse return null;
    const name = sema.tree.tokenSlice(binding.name_token);
    for (nodes[0..at]) |earlier| {
        const seen = sema.bindingOf(earlier) orelse continue;
        if (std.mem.eql(u8, sema.tree.tokenSlice(seen.name_token), name)) {
            _ = try sema.fail(.redeclared, binding.name_token);
            return null;
        }
    }
    return binding;
}

fn bindingOf(sema: *Sema, node: Ast.Node.Index) ?Ast.View.Binding {
    return switch (sema.tree.viewOf(node)) {
        .param, .field => |binding| binding,
        else => null,
    };
}

/// Nominal: the declaration site makes it distinct, never the fields. `owner` is where the
/// name comes from, and what lets a field point back at it before the fields resolve.
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

/// `blame` is the owning declaration when there is one, since the cycle belongs to the
/// type rather than to whichever field happened to close it.
fn resolveStructFields(
    sema: *Sema,
    ty: Type.Index,
    fields: []const Ast.Node.Index,
    blame: ?Token,
) Allocator.Error!void {
    const base = sema.scratch.items.len;
    defer sema.scratch.shrinkRetainingCapacity(base);

    // Local, because no field's type resolves through here.
    var names: std.ArrayList(InternPool.String) = .empty;
    defer names.deinit(sema.gpa);

    for (0..fields.len) |at| {
        const field = (try sema.bindingIn(fields, at)) orelse continue;

        var field_ty = try sema.evalTypeExpr(field.type_expr, field.name_token);
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

    for (0..function.params.len) |at| {
        const param = (try sema.bindingIn(function.params, at)) orelse continue;
        const param_ty = try sema.evalTypeExpr(param.type_expr, param.name_token);
        try sema.scratch.append(sema.gpa, param_ty);
    }

    const return_type = if (function.return_type.unwrap()) |node|
        try sema.evalTypeExpr(node, function.name_token)
    else
        .void;

    return sema.pool.intern(sema.gpa, .{ .func = .{
        .params = sema.scratch.items[base..],
        .return_type = return_type,
    } });
}
