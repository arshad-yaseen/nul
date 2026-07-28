//! The container's declaration table; what a declaration means is `Sema`'s. Every name
//! is bound before any is resolved, which lets declarations refer to each other in any
//! order.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Type = @import("Type.zig");
const Value = @import("Value.zig");

const Namespace = @This();

decls: std.ArrayList(Decl),
/// Positions in `decls`, keyed on the name's source bytes.
by_name: std.StringHashMapUnmanaged(u32),

pub const Decl = struct {
    name_token: Ast.TokenIndex,
    node: Ast.Node.Index,
    state: State = .unresolved,
    /// A struct declaration binds a value whose type is `type`.
    value: Value = .poisoned,

    /// `in_progress` turns a self-dependency into a report instead of a hang.
    pub const State = enum { unresolved, in_progress, resolved };
};

/// A declaration's identity, stable for the life of the compilation.
pub const Index = enum(u32) { _ };

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

        // Imports are exempt, since `use std.mem.Arena` binds the builtin itself.
        if (tree.nodeTag(node) != .use_decl and Type.builtinNamed(name) != null) {
            try diagnostics.add(.{
                .tag = .shadows_builtin,
                .token = name_token,
                .text = "this name belongs to a builtin type",
                .notes = try diagnostics.notes(&.{.{
                    .kind = .help,
                    .text = "pick another name, since a builtin type cannot be rebound",
                }}),
            });
            continue;
        }

        const found = try ns.by_name.getOrPut(gpa, name);
        if (found.found_existing) {
            const first = ns.decls.items[found.value_ptr.*].name_token;
            try diagnostics.add(.{
                .tag = .redeclared,
                .token = name_token,
                .text = "declared again here",
                .marks = try diagnostics.mark(
                    first,
                    try diagnostics.print("'{s}' was first declared here", .{name}),
                ),
            });
            continue;
        }
        found.value_ptr.* = @intCast(ns.decls.items.len);
        try ns.decls.append(gpa, .{ .name_token = name_token, .node = node });
    }
    return ns;
}

fn declaredName(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    return switch (tree.viewOf(node)) {
        .var_decl => |it| it.name_token,
        .fn_decl => |it| it.name_token,
        // An import binds the last segment, so `use std.mem.Arena` is `Arena`.
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

pub fn find(ns: *const Namespace, name: []const u8) ?Index {
    const at = ns.by_name.get(name) orelse return null;
    return @enumFromInt(at);
}

pub fn decl(ns: *Namespace, index: Index) *Decl {
    return &ns.decls.items[@intFromEnum(index)];
}

pub fn all(ns: *Namespace) []Decl {
    return ns.decls.items;
}
