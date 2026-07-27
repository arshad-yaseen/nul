//! The container's declaration table: which names it declares, and where each one is
//! written. What a declaration *means* is `Sema`'s, because working that out is
//! evaluation, and evaluation needs the pool, the errors and the rest of the pass.
//!
//! Every name is bound before any is resolved, which is what lets declarations refer to
//! each other in any order.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Error = @import("Error.zig");
const InternPool = @import("InternPool.zig");
const Type = @import("Type.zig");

const Namespace = @This();

decls: std.ArrayList(Decl),
/// Positions in `decls`, keyed on the name's source bytes.
by_name: std.StringHashMapUnmanaged(u32),

/// Collection fills in where the declaration is written. `Sema` fills in the rest, and
/// owns every change to `state`, `ty` and `value` from then on.
pub const Decl = struct {
    name_token: Ast.TokenIndex,
    /// The `var_decl`, `fn_decl` or `use_decl` this was collected from.
    node: Ast.Node.Index,
    state: State = .unresolved,
    /// A declaration binds a name to both. `let Node = struct {...}` has type `type` and
    /// value the struct type itself.
    ty: Type.Index = .never,
    value: InternPool.Index = .never,

    /// Resolution follows dependencies rather than the source, so it can arrive back at a
    /// declaration it is already inside. `in_progress` is what turns that into a report
    /// instead of a hang.
    pub const State = enum { unresolved, in_progress, resolved };
};

pub const empty: Namespace = .{ .decls = .empty, .by_name = .empty };

/// Walks the container once, binding every name it declares. A name that collides is
/// reported and the first one kept, so resolution afterwards sees no duplicates.
pub fn collect(
    gpa: Allocator,
    tree: *const Ast,
    errors: *Error.List,
) Allocator.Error!Namespace {
    var ns: Namespace = .empty;
    errdefer ns.deinit(gpa);

    for (tree.viewOf(.root).root) |node| {
        const name_token = declaredName(tree, node) orelse continue;
        const name = tree.tokenSlice(name_token);

        // An import is exempt, because `use std.mem.Arena` binds the `Arena` that *is* the
        // builtin rather than a second one hiding it.
        if (tree.nodeTag(node) != .use_decl and InternPool.builtinNamed(name) != null) {
            try errors.add(gpa, .{ .tag = .shadows_builtin, .token = name_token });
            continue;
        }

        const found = try ns.by_name.getOrPut(gpa, name);
        if (found.found_existing) {
            try errors.add(gpa, .{ .tag = .redeclared, .token = name_token });
            continue;
        }
        found.value_ptr.* = @intCast(ns.decls.items.len);
        try ns.decls.append(gpa, .{ .name_token = name_token, .node = node });
    }
    return ns;
}

/// The name a top level node binds, or null for one that binds nothing.
fn declaredName(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    return switch (tree.viewOf(node)) {
        .var_decl => |decl| decl.name_token,
        .fn_decl => |decl| decl.name_token,
        // An import binds the last segment of its path: `use std.mem.Arena` is `Arena`.
        .use_decl => |path| switch (tree.viewOf(path)) {
            .field_access => |access| access.name_token,
            .ident => |token| token,
            else => null,
        },
        else => null,
    };
}

pub fn deinit(ns: *Namespace, gpa: Allocator) void {
    ns.decls.deinit(gpa);
    ns.by_name.deinit(gpa);
    ns.* = undefined;
}

/// The pointer stays valid for as long as resolution runs: the table stops growing when
/// collection ends, and nothing resolves before then.
pub fn find(ns: *Namespace, name: []const u8) ?*Decl {
    const at = ns.by_name.get(name) orelse return null;
    return &ns.decls.items[at];
}

/// In source order, which is the order they were collected in.
pub fn all(ns: *Namespace) []Decl {
    return ns.decls.items;
}
