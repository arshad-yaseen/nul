//! Semantic analysis: gives every declaration in the container a type and a value.
//!
//! `Namespace` says which names exist. This says what they mean, which means evaluating,
//! because a type annotation is a compile time expression and running it is what interns
//! the types everything downstream compares by index.
//!
//! Nothing here walks in source order. A declaration is resolved when something needs it,
//! so `resolveDecl` and `evalTypeExpr` call each other until the dependency is met or
//! found to be circular.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Error = @import("Error.zig");
const InternPool = @import("InternPool.zig");
const Namespace = @import("Namespace.zig");
const Type = @import("Type.zig");

const Sema = @This();
const Decl = Namespace.Decl;
const Token = Ast.TokenIndex;

gpa: Allocator,
pool: *InternPool,
/// Borrowed, and must outlive this.
tree: *const Ast,
namespace: *Namespace,
errors: *Error.List,
/// One stack for every type list under construction: a struct's fields, a function's
/// parameters. Each user takes the length on entry and shrinks back to it on the way out,
/// so nesting costs one allocation overall rather than one per list.
scratch: std.ArrayList(Type.Index),

pub fn init(
    gpa: Allocator,
    pool: *InternPool,
    tree: *const Ast,
    namespace: *Namespace,
    errors: *Error.List,
) Sema {
    return .{
        .gpa = gpa,
        .pool = pool,
        .tree = tree,
        .namespace = namespace,
        .errors = errors,
        .scratch = .empty,
    };
}

pub fn deinit(sema: *Sema) void {
    sema.scratch.deinit(sema.gpa);
    sema.* = undefined;
}

/// Reporting never stops the pass. Whatever could not be worked out becomes `never`, and
/// resolution carries on so one mistake yields one message.
fn fail(sema: *Sema, tag: Error.Tag, token: Token) Allocator.Error!void {
    return sema.errors.add(sema.gpa, .{ .tag = tag, .token = token });
}

// Declarations

/// Resolves the whole container, then puts the errors back in source order.
pub fn resolveDeclarations(sema: *Sema) Allocator.Error!void {
    for (sema.namespace.all()) |*decl| try sema.resolveDecl(decl);
    sema.errors.sortBySource();
}

/// Gives `decl` its type and value, at most once.
///
/// Reentrant: resolving one declaration evaluates type expressions that name others. The
/// state is what makes that safe, since finding a declaration already `in_progress` means
/// it needs itself.
fn resolveDecl(sema: *Sema, decl: *Decl) Allocator.Error!void {
    switch (decl.state) {
        .resolved => return,
        .in_progress => {
            try sema.fail(.depends_on_itself, decl.name_token);
            // Left as `never`, so whatever was waiting on it gets an answer and reports
            // nothing further.
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

/// A `let` or `var`: the initializer says what the declaration is, and an annotation then
/// has to agree with it.
fn resolveBinding(sema: *Sema, decl: *Decl, binding: Ast.View.VarDecl) Allocator.Error!void {
    try sema.bindInitializer(decl, binding.init_expr);
    if (binding.type_expr.unwrap()) |annotation| try sema.applyAnnotation(decl, annotation);
}

/// Either the declaration is a value, whose type the initializer decides, or it is a type,
/// which is a value of type `type`. This is where that is settled.
fn bindInitializer(
    sema: *Sema,
    decl: *Decl,
    init_expr: Ast.Node.Index,
) Allocator.Error!void {
    switch (sema.tree.viewOf(init_expr)) {
        .number_literal => |token| decl.ty = try sema.numberLiteralType(token),
        .str_literal => decl.ty = .str,
        .bool_literal => decl.ty = .bool,
        // A named struct goes straight to `evalStructType`, which is the only place that
        // needs to know which declaration a struct belongs to.
        .struct_type => |fields| {
            decl.value = try sema.evalStructType(init_expr, fields, decl);
            decl.ty = .type;
        },
        // Everything else is read as a type expression, so `let Ptr = *Node` works and
        // `let x = f()` reports that this cannot evaluate it yet.
        else => {
            decl.value = try sema.evalTypeExpr(init_expr, decl.name_token);
            decl.ty = .type;
        },
    }
}

/// A written type has the final say, so it replaces the inferred one, but only after the
/// two are checked to agree.
fn applyAnnotation(
    sema: *Sema,
    decl: *Decl,
    annotation: Ast.Node.Index,
) Allocator.Error!void {
    const declared = try sema.evalTypeExpr(annotation, decl.name_token);
    // `coerce` answers for the type and not the value: whether `300` fits a `u8` needs the
    // literal itself, which is a check for whoever holds it. A `never` on either side is a
    // failure that already reported, and saying so again in different words helps nobody.
    if (declared != .never and decl.ty != .never and
        Type.coerce(sema.pool, decl.ty, declared) == null)
    {
        try sema.fail(.type_mismatch, sema.tree.nodeMainToken(annotation));
    }
    decl.ty = declared;
}

/// The builtins are the only part of `std` that exists before the module resolver does.
/// Anything else stays bound but unresolved, claiming nothing either way, which is why an
/// import that resolves to nothing reports nothing.
fn resolveImport(sema: *Sema, decl: *Decl) void {
    const builtin = InternPool.builtinNamed(sema.tree.tokenSlice(decl.name_token)) orelse
        return;
    decl.ty = .type;
    decl.value = builtin;
}

// Type expressions

/// The type a type expression denotes.
///
/// `blame` is the token an unevaluable expression is reported against, since its own is
/// often punctuation: for a call it is the `(`.
fn evalTypeExpr(
    sema: *Sema,
    node: Ast.Node.Index,
    blame: Token,
) Allocator.Error!Type.Index {
    switch (sema.tree.viewOf(node)) {
        .ident => |token| return sema.evalNamedType(token),
        .pointer_type => |pointer| {
            // Only the pointee's identity is needed and never its body, which is what
            // lets two struct types refer to each other.
            const pointee = try sema.evalTypeExpr(pointer.child, blame);
            return sema.pool.intern(sema.gpa, .{ .pointer = .{
                .pointee = pointee,
                .is_mutable = pointer.is_mutable,
            } });
        },
        .struct_type => |fields| return sema.evalStructType(node, fields, null),
        .grouped => |inner| return sema.evalTypeExpr(inner, blame),
        .err => return .never, // the parser already reported it
        else => {
            try sema.fail(.unsupported_value, blame);
            return .never;
        },
    }
}

/// A name used where a type is expected. This is the edge that makes resolution
/// order independent: the declaration it names is resolved here if it has not been.
fn evalNamedType(sema: *Sema, token: Token) Allocator.Error!Type.Index {
    const name = sema.tree.tokenSlice(token);
    // A builtin wins, so no declaration can rebind `i64`. `Namespace.collect` rejects one
    // that tries, so this only settles the order and not the outcome.
    if (InternPool.builtinNamed(name)) |builtin| return builtin;

    const decl = sema.namespace.find(name) orelse {
        try sema.fail(.undefined_name, token);
        return .never;
    };
    try sema.resolveDecl(decl);

    if (decl.ty == .never) return .never; // a failure that already reported
    if (decl.ty != .type) {
        try sema.fail(.not_a_type, token);
        return .never;
    }
    return decl.value;
}

/// The one place a literal's spelling becomes a type. The tokenizer accepts more than is
/// valid, so a number that is not one is caught here rather than there.
fn numberLiteralType(sema: *Sema, token: Token) Allocator.Error!Type.Index {
    const number = Type.parseNumber(sema.tree.tokenSlice(token)) catch |err| {
        try sema.fail(switch (err) {
            error.InvalidDigit => .invalid_digit,
            error.TooLarge => .literal_too_large,
        }, token);
        return .never;
    };
    return Type.numberType(number);
}

// Composite types

/// A struct type is nominal: the declaration site is what makes it distinct, never the
/// fields, so two identically shaped bodies are two types.
///
/// `owner` is the declaration it is bound to, when it has one. That is where its name
/// comes from, and it is what lets a field point back at it before the fields resolve.
fn evalStructType(
    sema: *Sema,
    node: Ast.Node.Index,
    fields: []const Ast.Node.Index,
    owner: ?*Decl,
) Allocator.Error!Type.Index {
    const id: InternPool.NominalId = @enumFromInt(@intFromEnum(node));
    const name = if (owner) |decl|
        try sema.pool.internString(sema.gpa, sema.tree.tokenSlice(decl.name_token))
    else
        .empty;
    const ty = try sema.pool.declareStruct(sema.gpa, id, name);

    // Finished before a single field is looked at, so `next: *Node` finds a `Node`.
    // Whether the *body* has arrived is the pool's business, via `isDefined`.
    if (owner) |decl| {
        decl.ty = .type;
        decl.value = ty;
        decl.state = .resolved;
    }

    try sema.resolveStructFields(ty, fields);
    return ty;
}

/// Fills in the body that `declareStruct` left open.
fn resolveStructFields(
    sema: *Sema,
    ty: Type.Index,
    fields: []const Ast.Node.Index,
) Allocator.Error!void {
    const base = sema.scratch.items.len;
    defer sema.scratch.shrinkRetainingCapacity(base);

    // Local rather than a second scratch, because no field's type resolves through here.
    var names: std.ArrayList(InternPool.String) = .empty;
    defer names.deinit(sema.gpa);

    for (fields) |field_node| {
        const field = switch (sema.tree.viewOf(field_node)) {
            .field => |it| it,
            else => continue, // the parser already reported it
        };

        var field_ty = try sema.evalTypeExpr(field.type_expr, field.name_token);
        // A field held by value needs a size where a pointer to one does not, so this
        // catches only the cycles that genuinely cannot be laid out.
        if (!sema.pool.isDefined(field_ty)) {
            try sema.fail(.depends_on_itself, field.name_token);
            field_ty = .never;
        }

        try sema.scratch.append(sema.gpa, field_ty);
        try names.append(
            sema.gpa,
            try sema.pool.internString(sema.gpa, sema.tree.tokenSlice(field.name_token)),
        );
    }

    try sema.pool.defineStruct(sema.gpa, ty, names.items, sema.scratch.items[base..]);
}

/// A function's type is its signature and nothing else, which is what lets a call be
/// checked without ever reading the body.
fn evalFuncType(sema: *Sema, function: Ast.View.FnDecl) Allocator.Error!Type.Index {
    const base = sema.scratch.items.len;
    defer sema.scratch.shrinkRetainingCapacity(base);

    for (function.params) |param_node| {
        const param = switch (sema.tree.viewOf(param_node)) {
            .param => |it| it,
            else => continue, // the parser already reported it
        };
        const param_ty = try sema.evalTypeExpr(param.type_expr, param.name_token);
        try sema.scratch.append(sema.gpa, param_ty);
    }

    // An omitted return type is `void` rather than inferred, for the same reason.
    const return_type = if (function.return_type.unwrap()) |node|
        try sema.evalTypeExpr(node, function.name_token)
    else
        .void;

    return sema.pool.intern(sema.gpa, .{ .func = .{
        .params = sema.scratch.items[base..],
        .return_type = return_type,
    } });
}
