//! A module is one file, however it is reached. Loading parses and registers
//! declarations, and never analyzes, so imports cannot recurse. Resolution
//! turns a `use` path into a file on disk, loads it once, and follows
//! re-exports to the declaration they name.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Compilation = @import("Compilation.zig");
const Diagnostic = @import("Diagnostic.zig");
const Pool = @import("Pool.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

/// The identity key, `space:stem/stem`, so one file is one module.
key: []const u8,
source: Source,
tree: AST,
space: Space,
/// This module's rows in the one declaration table, members included.
decls_start: u32,
decls_len: u32,
/// Top-level name lookup. Members are found through their struct instead.
names: std.AutoHashMapUnmanaged(Pool.String, Decl.Index),
/// A module that failed to parse reported its own errors and is never analyzed.
failed: bool,

const Module = @This();

pub const Index = enum(u32) {
    root = 0,
    _,

    pub fn int(index: Index) u32 {
        return @intFromEnum(index);
    }
};

/// Which directory a module resolves against. `std.` selects the second, and
/// only modules already inside it may bind the primitives.
pub const Space = enum { root, std };

/// One declaration. The row is the identity everything else refers to.
/// Method resolution, instantiation, and re-export all compare these indexes.
pub const Decl = struct {
    module: Module.Index,
    node: AST.Node.Index,
    name: Pool.String,
    /// For a member function, the struct declaration it belongs to.
    owner: OptionalIndex,
    /// What resolution left behind. A `type_alias` or `let` stores a pool
    /// row, a `use` stores the target its `aux` kind explains, and a struct
    /// holds its member range together with `aux`.
    result: u32,
    aux: u32,
    kind: Kind,
    state: State,
    /// A struct with a bound arena operation is the region type. Set at
    /// registration, before any signature resolves, so the type knows itself.
    is_region: bool,

    pub const Kind = enum(u8) { use, struct_decl, type_alias, let, fn_decl };
    pub const State = enum(u8) { unanalyzed, in_progress, done, poisoned };

    /// What a resolved `use` points at, stored in `aux` beside the payload.
    pub const UseTarget = enum(u8) { module, decl, builtin };

    pub const Index = enum(u32) {
        _,

        pub fn int(index: Decl.Index) u32 {
            return @intFromEnum(index);
        }

        pub fn toOptional(index: Decl.Index) OptionalIndex {
            const optional: OptionalIndex = @enumFromInt(@intFromEnum(index));
            assert(optional != .none);
            return optional;
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(optional: OptionalIndex) ?Decl.Index {
            if (optional == .none) return null;
            return @enumFromInt(@intFromEnum(optional));
        }
    };

    /// The primitive a `= builtin.name` body bound, if any.
    pub fn builtin(decl: Decl) ?Compilation.Builtin {
        if (decl.kind != .fn_decl) return null;
        if (decl.aux == 0) return null;
        return @enumFromInt(decl.aux - 1);
    }

    /// A struct's member declarations sit contiguously after it.
    pub fn members(decl: Decl) struct { start: u32, len: u32 } {
        assert(decl.kind == .struct_decl);
        return .{ .start = decl.result, .len = decl.aux };
    }
};

pub fn deinit(module: *Module, gpa: Allocator) void {
    module.tree.deinit(gpa);
    module.source.deinit(gpa);
    module.names.deinit(gpa);
    module.* = undefined;
}

pub fn findDecl(module: *const Module, name: Pool.String) ?Decl.Index {
    return module.names.get(name);
}

/// How a message names this module, the key without its space prefix.
pub fn displayName(module: *const Module) []const u8 {
    const colon = std.mem.indexOfScalar(u8, module.key, ':').?;
    assert(colon + 1 < module.key.len);
    return module.key[colon + 1 ..];
}

/// Parse one loaded source and register its declarations. Parse errors are
/// copied out and the module is marked failed, so nothing ever analyzes it.
pub fn register(
    comp: *Compilation,
    key: []const u8,
    space: Space,
    source: Source,
) Allocator.Error!Module.Index {
    assert(key.len > 0);
    assert(comp.module_map.get(key) == null);

    const gpa = comp.gpa;
    const module = try gpa.create(Module);
    errdefer gpa.destroy(module);

    const index: Module.Index = @enumFromInt(@as(u32, @intCast(comp.modules.items.len)));
    module.* = .{
        .key = key,
        .source = source,
        .tree = try AST.parse(gpa, source.bytes),
        .space = space,
        .decls_start = @intCast(comp.decls.items.len),
        .decls_len = 0,
        .names = .empty,
        .failed = false,
    };

    // registration is the ownership boundary. from here the module is in the
    // table and deinit is the root object's job, so no error path frees it
    try comp.modules.append(gpa, module);
    try comp.module_map.put(gpa, key, index);

    if (module.tree.errors.len > 0) {
        module.failed = true;
        try comp.diagnostics.ensureUnusedCapacity(gpa, module.tree.errors.len);
        for (module.tree.errors) |diagnostic| {
            comp.diagnostics.appendAssumeCapacity(.{ .module = index, .diagnostic = diagnostic });
        }
        return index;
    }

    try registerDecls(comp, module, index);
    module.decls_len = @intCast(comp.decls.items.len - module.decls_start);
    return index;
}

fn registerDecls(comp: *Compilation, module: *Module, index: Module.Index) Allocator.Error!void {
    assert(module.tree.errors.len == 0);
    const tree = &module.tree;
    const root = tree.viewOf(.root).root;

    // only the standard library may name the primitives, and a binding is
    // recognized before anything resolves, so the region type knows itself
    var binds_builtin = false;
    if (module.space == .std) {
        for (root) |node| {
            if (usePathIsBuiltin(tree, node)) binds_builtin = true;
        }
    }

    try comp.decls.ensureUnusedCapacity(comp.gpa, root.len * 2);
    try module.names.ensureTotalCapacity(comp.gpa, @intCast(root.len));

    for (root) |node| {
        switch (tree.viewOf(node)) {
            .use_decl => |use| {
                const name_token = lastPathComponent(tree, use.path) orelse continue;
                _ = try addDecl(comp, module, index, .{
                    .kind = .use,
                    .node = node,
                    .name_token = name_token,
                });
            },
            .struct_decl => |decl| {
                const struct_index = try addDecl(comp, module, index, .{
                    .kind = .struct_decl,
                    .node = node,
                    .name_token = decl.name_token,
                }) orelse continue;
                try registerMembers(comp, module, index, struct_index, decl, binds_builtin);
            },
            .type_decl => |decl| _ = try addDecl(comp, module, index, .{
                .kind = .type_alias,
                .node = node,
                .name_token = decl.name_token,
            }),
            .fn_decl => |decl| _ = try addDecl(comp, module, index, .{
                .kind = .fn_decl,
                .node = node,
                .name_token = decl.name_token,
            }),
            .var_decl => |decl| _ = try addDecl(comp, module, index, .{
                .kind = .let,
                .node = node,
                .name_token = decl.name_token,
            }),
            // the parser only puts declarations and holes at the root
            .err => {},
            else => unreachable,
        }
    }
}

/// Members sit contiguously after their struct's own row, and a body that is
/// exactly `builtin.name` binds that primitive instead of having a body.
fn registerMembers(
    comp: *Compilation,
    module: *Module,
    index: Module.Index,
    struct_index: Decl.Index,
    decl: AST.View.StructDecl,
    binds_builtin: bool,
) Allocator.Error!void {
    const tree = &module.tree;
    const members_start: u32 = @intCast(comp.decls.items.len);

    for (decl.members) |member| {
        switch (tree.viewOf(member)) {
            .fn_decl => |fn_view| {
                const member_index = try addMember(comp, module, index, struct_index, .{
                    .kind = .fn_decl,
                    .node = member,
                    .name_token = fn_view.name_token,
                }) orelse continue;

                if (binds_builtin) {
                    if (boundBuiltin(tree, fn_view.body)) |bound| {
                        comp.decls.items[member_index.int()].aux = @intFromEnum(bound) + 1;
                        comp.decls.items[struct_index.int()].is_region = true;
                    }
                }
            },
            .field => {},
            .err => {},
            else => unreachable,
        }
    }

    comp.decls.items[struct_index.int()].result = members_start;
    comp.decls.items[struct_index.int()].aux = @intCast(comp.decls.items.len - members_start);
}

const NewDecl = struct { kind: Decl.Kind, node: AST.Node.Index, name_token: Token.Index };

fn addDecl(
    comp: *Compilation,
    module: *Module,
    index: Module.Index,
    new: NewDecl,
) Allocator.Error!?Decl.Index {
    const tree = &module.tree;
    const text = tree.tokenSlice(new.name_token);
    if (tree.tokenTag(new.name_token) != .ident) return null;

    const name = try comp.pool.string(comp.gpa, text);
    const decl_index = try appendDecl(comp, index, new, name, .none);

    if (std.mem.eql(u8, text, "_")) {
        try comp.reportToken(index, new.name_token, .{
            .code = .discard_reserved,
            .message = "'_' cannot be declared, it is how a value is discarded",
            .label = "not a name",
            .help = "give this declaration a real name",
        });
        comp.decls.items[decl_index.int()].state = .poisoned;
        return decl_index;
    }

    if (comp.universalType(name) != null) {
        try comp.reportToken(index, new.name_token, .{
            .code = .shadows,
            .message = try comp.fmt("'{s}' is already the name of a type every file can see", .{
                text,
            }),
            .label = "a universal name",
            .help = "pick another name, and alias it with 'type' if you want a synonym",
        });
        comp.decls.items[decl_index.int()].state = .poisoned;
        return decl_index;
    }

    const gop = module.names.getOrPutAssumeCapacity(name);
    if (gop.found_existing) {
        const first = comp.decls.items[gop.value_ptr.int()];
        try comp.reportToken(index, new.name_token, .{
            .code = .redeclared,
            .message = try comp.fmt("'{s}' is declared twice in this file", .{text}),
            .label = "declared again here",
            .notes = try comp.notes(&.{comp.noteAt(index, first.node, "first declared here")}),
        });
        comp.decls.items[decl_index.int()].state = .poisoned;
        return decl_index;
    }
    gop.value_ptr.* = decl_index;
    return decl_index;
}

fn addMember(
    comp: *Compilation,
    module: *Module,
    index: Module.Index,
    owner: Decl.Index,
    new: NewDecl,
) Allocator.Error!?Decl.Index {
    const tree = &module.tree;
    if (tree.tokenTag(new.name_token) != .ident) return null;
    const text = tree.tokenSlice(new.name_token);
    const name = try comp.pool.string(comp.gpa, text);

    // a member clashes with a field or an earlier member of the same struct
    const clash: ?AST.Node.Index = clash: {
        const owner_row = comp.decls.items[owner.int()];
        const struct_view = tree.viewOf(owner_row.node).struct_decl;
        for (struct_view.members) |other| {
            if (other == new.node) break;
            const other_name = switch (tree.viewOf(other)) {
                .field => |field| field.name_token,
                .fn_decl => |member_fn| member_fn.name_token,
                .err => continue,
                else => unreachable,
            };
            if (std.mem.eql(u8, tree.tokenSlice(other_name), text)) break :clash other;
        }
        break :clash null;
    };

    const decl_index = try appendDecl(comp, index, new, name, owner.toOptional());
    if (clash) |first| {
        try comp.reportToken(index, new.name_token, .{
            .code = .redeclared,
            .message = try comp.fmt("'{s}' is declared twice in this struct", .{text}),
            .label = "declared again here",
            .notes = try comp.notes(&.{comp.noteAt(index, first, "first declared here")}),
        });
        comp.decls.items[decl_index.int()].state = .poisoned;
    }
    return decl_index;
}

fn appendDecl(
    comp: *Compilation,
    module_index: Module.Index,
    new: NewDecl,
    name: Pool.String,
    owner: Decl.OptionalIndex,
) Allocator.Error!Decl.Index {
    if (comp.decls.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const index: Decl.Index = @enumFromInt(@as(u32, @intCast(comp.decls.items.len)));
    try comp.decls.append(comp.gpa, .{
        .module = module_index,
        .node = new.node,
        .name = name,
        .owner = owner,
        .result = 0,
        .aux = 0,
        .kind = new.kind,
        .state = .unanalyzed,
        .is_region = false,
    });
    return index;
}

/// Whether a root declaration is exactly `use builtin`.
fn usePathIsBuiltin(tree: *const AST, node: AST.Node.Index) bool {
    if (tree.nodeTag(node) != .use_decl) return false;
    const use = tree.viewOf(node).use_decl;
    if (tree.nodeTag(use.path) != .ident) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(use.path)), "builtin");
}

/// The primitive a function body names, when the body is `builtin.name` and
/// the name is one the compiler exports. A misspelled name is not a binding,
/// so the body stays ordinary and analysis reports the name where it is read.
fn boundBuiltin(tree: *const AST, body: AST.Node.Index) ?Compilation.Builtin {
    if (tree.nodeTag(body) != .field_access) return null;
    const access = tree.viewOf(body).field_access;
    if (tree.nodeTag(access.lhs) != .ident) return null;

    const base = tree.tokenSlice(tree.nodeMainToken(access.lhs));
    if (std.mem.eql(u8, base, "builtin") == false) return null;

    const name = tree.tokenSlice(access.name_token);
    return std.meta.stringToEnum(Compilation.Builtin, name);
}

/// The token naming what a `use` binds, the last component of its path.
pub fn lastPathComponent(tree: *const AST, path: AST.Node.Index) ?Token.Index {
    return switch (tree.nodeTag(path)) {
        .ident => tree.nodeMainToken(path),
        .field_access => tree.viewOf(path).field_access.name_token,
        else => null,
    };
}

// modules on disk

const use_chain_max = 32;
const path_components_max = 32;

const Loaded = union(enum) { module: Module.Index, not_found, no_std };

/// Find and register a module by its relative path, once. `sub` is joined
/// from identifiers, so it cannot climb out of its space.
fn loadModule(comp: *Compilation, space: Space, sub: []const u8) Allocator.Error!Loaded {
    assert(sub.len > 0);

    const key = try comp.fmt("{t}:{s}", .{ space, sub });
    if (comp.module_map.get(key)) |index| {
        if (comp.modules.items[index.int()].failed) return .not_found;
        return .{ .module = index };
    }

    const base = switch (space) {
        .root => comp.root_dir,
        .std => comp.std_dir orelse return .no_std,
    };
    const path = try std.fs.path.join(comp.arena.allocator(), &.{
        base,
        try comp.fmt("{s}.nul", .{sub}),
    });

    const source = Source.load(comp.gpa, comp.io, .cwd(), path) catch |err| switch (err) {
        error.ReadFailed, error.SourceTooLarge => return .not_found,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const index = try register(comp, key, space, source);
    if (comp.modules.items[index.int()].failed) return .not_found;
    return .{ .module = index };
}

/// Resolve what a `use` names. It is a module, a module plus one trailing
/// public declaration, or the builtin floor, and the result lands in the
/// declaration row.
pub fn resolveUse(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    const decl = comp.decls.items[decl_index.int()];
    const module = comp.modules.items[decl.module.int()];
    const tree = &module.tree;
    const path = tree.viewOf(decl.node).use_decl.path;

    var names: [path_components_max][]const u8 = undefined;
    var nodes: [path_components_max]AST.Node.Index = undefined;
    const count = pathComponents(tree, path, &names, &nodes) orelse {
        try comp.reportNode(decl.module, path, .{
            .code = .module_not_found,
            .message = try comp.fmt("an import path nests more than {d} names deep", .{
                path_components_max,
            }),
        });
        return false;
    };
    assert(count > 0);

    if (count == 1 and std.mem.eql(u8, names[0], "builtin")) {
        if (module.space == .std) {
            setUseTarget(comp, decl_index, .builtin, 0);
            return true;
        }
        try comp.reportNode(decl.module, path, .{
            .code = .builtin_outside_std,
            .message = "only the standard library can reach 'builtin'",
            .label = "not available here",
            .help = "the primitives are ordinary declarations in std; call those instead",
        });
        return false;
    }

    var space = module.space;
    var first: u32 = 0;
    if (std.mem.eql(u8, names[0], "std")) {
        space = .std;
        first = 1;
        if (count == 1) {
            try comp.reportNode(decl.module, path, .{
                .code = .module_not_found,
                .message = "'std' is a directory of modules, not a module",
                .label = "name one",
                .help = "'use std.mem' imports the memory module",
            });
            return false;
        }
    }

    // the whole path as a module wins. otherwise all but the last name a
    // module and the last is a declaration in it
    const whole = try std.mem.join(comp.arena.allocator(), "/", names[first..count]);
    switch (try loadModule(comp, space, whole)) {
        .module => |target| {
            setUseTarget(comp, decl_index, .module, target.int());
            return true;
        },
        .no_std => return reportNoStd(comp, decl.module, path),
        .not_found => {},
    }

    if (count - first >= 2) {
        const parent = try std.mem.join(comp.arena.allocator(), "/", names[first .. count - 1]);
        switch (try loadModule(comp, space, parent)) {
            .module => |target| {
                const last = nodes[count - 1];
                const name_token = switch (tree.nodeTag(last)) {
                    .field_access => tree.viewOf(last).field_access.name_token,
                    else => tree.nodeMainToken(last),
                };
                const found = try findExported(
                    comp,
                    target,
                    names[count - 1],
                    .{ .module = decl.module, .node = last },
                    .{ .start = tree.tokenStart(name_token), .end = tree.tokenEnd(name_token) },
                ) orelse return false;
                setUseTarget(comp, decl_index, .decl, found.int());
                return true;
            },
            .no_std => return reportNoStd(comp, decl.module, path),
            .not_found => {},
        }
    }

    const spelled = try std.mem.join(comp.arena.allocator(), ".", names[first..count]);
    try comp.reportNode(decl.module, path, .{
        .code = .module_not_found,
        .message = try comp.fmt("no module named '{s}'", .{spelled}),
        .label = "nothing on disk answers to this",
        .help = switch (space) {
            .root => try comp.fmt("modules live beside the root file, in '{s}'", .{
                comp.root_dir,
            }),
            .std => try comp.fmt("standard modules live in '{s}'", .{
                comp.std_dir orelse "<none>",
            }),
        },
    });
    return false;
}

fn setUseTarget(
    comp: *Compilation,
    decl_index: Decl.Index,
    target: Decl.UseTarget,
    payload: u32,
) void {
    comp.decls.items[decl_index.int()].aux = @intFromEnum(target);
    comp.decls.items[decl_index.int()].result = payload;
}

/// What a resolved `use` points at.
pub const UseResolved = union(enum) { module: Module.Index, decl: Decl.Index, builtin };

pub fn useTarget(comp: *const Compilation, decl_index: Decl.Index) UseResolved {
    const decl = comp.decls.items[decl_index.int()];
    assert(decl.kind == .use);
    assert(decl.state == .done);
    return switch (@as(Decl.UseTarget, @enumFromInt(decl.aux))) {
        .module => .{ .module = @enumFromInt(decl.result) },
        .decl => .{ .decl = @enumFromInt(decl.result) },
        .builtin => .builtin,
    };
}

/// A public declaration in another module, following re-exports to the end.
/// Reports at `at` and returns null when the name is missing or private.
pub fn findExported(
    comp: *Compilation,
    in: Module.Index,
    name_text: []const u8,
    origin: Compilation.Origin,
    at: Diagnostic.Span,
) Allocator.Error!?Decl.Index {
    var target = in;
    var remaining: u32 = use_chain_max;
    while (remaining > 0) : (remaining -= 1) {
        const module = comp.modules.items[target.int()];
        const name = try comp.pool.string(comp.gpa, name_text);

        const found = module.findDecl(name) orelse {
            try comp.report(origin.module, at, .{
                .code = .no_such_member,
                .message = try comp.fmt("'{s}' has no declaration named '{s}'", .{
                    module.displayName(), name_text,
                }),
                .label = "not found",
                .help = suggestIn(comp, module, name_text),
            });
            return null;
        };

        const decl = comp.decls.items[found.int()];
        if (origin.module != target and declIsPub(comp, found) == false) {
            try comp.report(origin.module, at, .{
                .code = .private,
                .message = try comp.fmt("'{s}' is private to its file", .{name_text}),
                .label = "not public",
                .help = "mark the declaration 'pub' to reach it from another file",
                .notes = try comp.notes(&.{
                    comp.noteAt(decl.module, decl.node, "declared here"),
                }),
            });
            return null;
        }

        if (decl.kind != .use) return found;

        // a re-export. resolve it and keep walking
        try comp.ensure(.forDecl(found), origin);
        if (comp.decls.items[found.int()].state != .done) return null;
        switch (useTarget(comp, found)) {
            .decl => |next| {
                const next_decl = comp.decls.items[next.int()];
                if (next_decl.kind != .use) return next;
                target = next_decl.module;
                continue;
            },
            // `pub use helper` re-exports a module name, and a declaration
            // was asked for, so there is nothing here to find
            .module, .builtin => return found,
        }
    }
    try comp.report(origin.module, at, .{
        .code = .value_cycle,
        .message = try comp.fmt("following '{s}' crossed {d} re-exports without arriving", .{
            name_text, use_chain_max,
        }),
    });
    return null;
}

pub fn declIsPub(comp: *const Compilation, decl_index: Decl.Index) bool {
    const decl = comp.decls.items[decl_index.int()];
    const tree = &comp.modules.items[decl.module.int()].tree;
    return switch (tree.viewOf(decl.node)) {
        .use_decl => |view| view.is_pub,
        .struct_decl => |view| view.is_pub,
        .type_decl => |view| view.is_pub,
        .fn_decl => |view| view.is_pub,
        .var_decl => |view| view.is_pub,
        else => false,
    };
}

fn reportNoStd(
    comp: *Compilation,
    module: Module.Index,
    node: AST.Node.Index,
) Allocator.Error!bool {
    try comp.reportNode(module, node, .{
        .code = .module_not_found,
        .message = "the standard library was not found",
        .label = "'std' has nowhere to point",
        .help = "pass --std <dir>, or run beside a 'lib/std' directory",
    });
    return false;
}

fn pathComponents(
    tree: *const AST,
    path: AST.Node.Index,
    names: *[path_components_max][]const u8,
    nodes: *[path_components_max]AST.Node.Index,
) ?u32 {
    var count: u32 = 0;
    var node = path;
    var depth: u32 = 0;
    // walk to the leftmost ident, collecting names right to left
    while (depth < path_components_max) : (depth += 1) {
        switch (tree.nodeTag(node)) {
            .ident => {
                if (count == path_components_max) return null;
                names[count] = tree.tokenSlice(tree.nodeMainToken(node));
                nodes[count] = node;
                count += 1;
                std.mem.reverse([]const u8, names[0..count]);
                std.mem.reverse(AST.Node.Index, nodes[0..count]);
                return count;
            },
            .field_access => {
                const view = tree.viewOf(node).field_access;
                if (count == path_components_max) return null;
                names[count] = tree.tokenSlice(view.name_token);
                nodes[count] = node;
                count += 1;
                node = view.lhs;
            },
            // a hole from a parse error never reaches analysis
            else => unreachable,
        }
    }
    return null;
}

/// The closest declared name, offered when a lookup misses.
fn suggestIn(comp: *Compilation, module: *const Module, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: u32 = 3;

    const decls_end = module.decls_start + module.decls_len;
    for (comp.decls.items[module.decls_start..decls_end]) |decl| {
        if (decl.owner != .none) continue;
        const candidate = comp.pool.stringText(decl.name);
        const distance = Compilation.editDistance(name, candidate);
        if (distance < best_distance) {
            best_distance = distance;
            best = candidate;
        }
    }
    const found = best orelse return null;
    return comp.fmt("did you mean '{s}'?", .{found}) catch null;
}
