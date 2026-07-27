//! The container's declaration table. What a declaration *means* is `Sema`'s.
//!
//! Every name is bound before any is resolved, which is what lets declarations refer to
//! each other in any order.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const InternPool = @import("InternPool.zig");
const Type = @import("Type.zig");

const Namespace = @This();

decls: std.ArrayList(Decl),
/// Positions in `decls`, keyed on the name's source bytes.
by_name: std.StringHashMapUnmanaged(u32),

/// Collection fills in where it is written; `Sema` owns everything after.
pub const Decl = struct {
    name_token: Ast.TokenIndex,
    node: Ast.Node.Index,
    state: State = .unresolved,
    /// `let Node = struct {...}` has type `type` and value the struct type itself.
    ty: Type.Index = .poisoned,
    value: InternPool.Index = .poisoned,

    /// `in_progress` turns a self-dependency into a report instead of a hang.
    pub const State = enum { unresolved, in_progress, resolved };

    /// Poison stays poison, so a failed declaration is never mistaken for a type.
    pub fn setType(decl: *Decl, ty: Type.Index) void {
        decl.ty = if (ty == .poisoned) .poisoned else .type;
        decl.value = ty;
    }
};

pub const empty: Namespace = .{ .decls = .empty, .by_name = .empty };

/// Binds every name the container declares, keeping the first of any that collide.
pub fn collect(
    gpa: Allocator,
    tree: *const Ast,
    diagnostics: *Diagnostic.List,
) Allocator.Error!Namespace {
    var ns: Namespace = .empty;
    errdefer ns.deinit(gpa);

    for (tree.viewOf(.root).root) |node| {
        const name_token = declaredName(tree, node) orelse continue;
        const name = tree.tokenSlice(name_token);

        // Imports are exempt: `use std.mem.Arena` binds the `Arena` that *is* the builtin.
        if (tree.nodeTag(node) != .use_decl and InternPool.builtinNamed(name) != null) {
            try diagnostics.add(gpa, .{ .tag = .shadows_builtin, .token = name_token });
            continue;
        }

        const found = try ns.by_name.getOrPut(gpa, name);
        if (found.found_existing) {
            try diagnostics.add(gpa, .{ .tag = .redeclared, .token = name_token });
            continue;
        }
        found.value_ptr.* = @intCast(ns.decls.items.len);
        try ns.decls.append(gpa, .{ .name_token = name_token, .node = node });
    }
    return ns;
}

fn declaredName(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    return switch (tree.viewOf(node)) {
        .var_decl => |decl| decl.name_token,
        .fn_decl => |decl| decl.name_token,
        // An import binds the last segment: `use std.mem.Arena` is `Arena`.
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

/// Stays valid: the table stops growing before anything resolves.
pub fn find(ns: *Namespace, name: []const u8) ?*Decl {
    const at = ns.by_name.get(name) orelse return null;
    return &ns.decls.items[at];
}

pub fn all(ns: *Namespace) []Decl {
    return ns.decls.items;
}
