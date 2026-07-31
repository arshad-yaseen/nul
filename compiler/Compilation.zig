//! The root object.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("AST.zig");
const Check = @import("Check.zig");
const Diagnostic = @import("Diagnostic.zig");
const IR = @import("IR.zig");
const Module = @import("Module.zig");
const Pool = @import("Pool.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const Decl = Module.Decl;

// tables

gpa: Allocator,
io: std.Io,
pool: Pool,
/// Heap-stable, because analysis holds a module while loading others.
modules: std.ArrayList(*Module),
module_map: std.StringHashMapUnmanaged(Module.Index),
decls: std.ArrayList(Decl),
instances: std.ArrayList(Instance),
instance_args: std.ArrayList(Pool.Index),
instance_map: std.HashMapUnmanaged(
    Pool.Instance,
    void,
    InstanceIndexContext,
    std.hash_map.default_max_load_percentage,
),
/// Signature parameters and struct fields share one row shape, so they share
/// one table. An instance holds a range into it, contiguous because rows are
/// staged in the scratch below and committed in one append.
rows: std.ArrayList(Row),
/// Staging for rows under construction, marked and restored, because
/// resolving one signature can demand another mid-way.
rows_scratch: std.ArrayList(Row),
funcs: std.ArrayList(IR.Func),
diagnostics: std.ArrayList(Entry),
/// One row per (module, code, offset), so re-walked code reports once.
reported: std.AutoHashMapUnmanaged(ReportKey, void),

// transient analysis state

/// What is being analyzed right now, the cycle chain and the trail.
stack: std.ArrayList(Frame),
/// Frames on the stack that are instantiations, capped at `instantiate_max`.
instance_depth: u32,
/// Recursion still on the native stack across all of checking, so nesting
/// that multiplies across declarations stays bounded. Capped at `depth_max`.
depth: u32,
/// The budget above ran out once already. Running out is one fact per
/// compilation, reported once.
depth_exhausted: bool,
/// Backs diagnostic text, module keys, and paths until deinit.
arena: std.heap.ArenaAllocator,

// configuration

/// Directory of the root file. Bare module paths resolve against it.
root_dir: []const u8,
/// Stem of the root file, its module name if something imports it back.
root_stem: []const u8,
/// Where `std.` resolves, when the compiler found or was given one.
std_dir: ?[]const u8,

const Compilation = @This();

pub const instantiate_max = 64;
/// How deep `ensure` may recurse for any reason, instantiating or not.
pub const analyze_max = 128;
/// The total recursion budget for one compilation. Declarations demand other
/// declarations mid-expression, so their depths multiply, and this is the one
/// bound on the product.
pub const depth_max = 3000;
const diagnostics_max = 256;

/// The six primitives, the compiler's whole floor. They are effects, so they
/// exist at run time and become IR instructions. A future question, `size_of`
/// say, is one more line here, folded at compile time with no instruction.
pub const Builtin = enum(u8) {
    arena_init,
    arena_child,
    arena_create,
    arena_copy,
    arena_reset,
    arena_destroy,

    pub const Kind = enum { effect, question };

    pub fn kind(builtin: Builtin) Kind {
        return switch (builtin) {
            .arena_init,
            .arena_child,
            .arena_create,
            .arena_copy,
            .arena_reset,
            .arena_destroy,
            => .effect,
        };
    }
};

/// One instantiation, a declaration plus its bracket arguments, memoized so
/// identity is the row. A member function's arguments start with its owner's.
pub const Instance = struct {
    decl: Decl.Index,
    args_start: u32,
    args_len: u32,
    /// A struct's interned type, or a function's return type once its
    /// signature resolves.
    type: Pool.Index,
    /// Fields for a struct, parameters for a function.
    rows_start: u32,
    rows_len: u32,
    /// The checked body. Stays `.none` for a bound primitive.
    func: IR.Func.Index,
    /// Fields resolved, or signature resolved.
    rows_state: Decl.State,
    /// The size walk, or the body check.
    deep_state: Decl.State,
};

/// A parameter or a field. One named, typed row.
pub const Row = struct {
    name: Pool.String,
    type: Pool.Index,
    node: AST.Node.Index,
};

/// One memoized computation. `ensure` is the only way to run one.
pub const Unit = struct {
    kind: Kind,
    index: u32,

    pub const Kind = enum(u8) { decl, rows, size, signature, body };

    pub fn forDecl(index: Decl.Index) Unit {
        return .{ .kind = .decl, .index = index.int() };
    }

    pub fn of(kind: Kind, instance: Pool.Instance) Unit {
        assert(kind != .decl);
        return .{ .kind = kind, .index = instance.int() };
    }

    fn eql(unit: Unit, other: Unit) bool {
        if (unit.kind != other.kind) return false;
        return unit.index == other.index;
    }
};

/// Where a demand came from, the reference that will be named if it closes a
/// cycle, and the trail entry if a diagnostic fires deeper in.
pub const Origin = struct { module: Module.Index, node: AST.Node.Index };

const Frame = struct { unit: Unit, origin: Origin };

const ReportKey = struct { module: Module.Index, code: Diagnostic.Code, offset: u32 };

pub const Entry = struct { module: Module.Index, diagnostic: Diagnostic };

pub const Options = struct {
    /// The root file, as given on the command line.
    root_path: []const u8,
    /// Where the standard library lives, or null when none was found.
    std_dir: ?[]const u8,
};

pub fn init(comp: *Compilation, gpa: Allocator, io: std.Io, options: Options) Allocator.Error!void {
    assert(options.root_path.len > 0);

    comp.* = .{
        .gpa = gpa,
        .io = io,
        .pool = undefined,
        .modules = .empty,
        .module_map = .empty,
        .decls = .empty,
        .instances = .empty,
        .instance_args = .empty,
        .instance_map = .empty,
        .rows = .empty,
        .rows_scratch = .empty,
        .funcs = .empty,
        .diagnostics = .empty,
        .reported = .empty,
        .stack = .empty,
        .instance_depth = 0,
        .depth = 0,
        .depth_exhausted = false,
        .arena = .init(gpa),
        .root_dir = std.fs.path.dirname(options.root_path) orelse ".",
        .root_stem = std.fs.path.stem(options.root_path),
        .std_dir = options.std_dir,
    };
    try comp.pool.init(gpa);
}

pub fn deinit(comp: *Compilation) void {
    const gpa = comp.gpa;

    for (comp.modules.items) |module| {
        module.deinit(gpa);
        gpa.destroy(module);
    }
    comp.modules.deinit(gpa);
    comp.module_map.deinit(gpa);

    for (comp.funcs.items) |*func| func.deinit(gpa);
    comp.funcs.deinit(gpa);

    comp.pool.deinit(gpa);
    comp.decls.deinit(gpa);
    comp.instances.deinit(gpa);
    comp.instance_args.deinit(gpa);
    comp.instance_map.deinit(gpa);
    comp.rows.deinit(gpa);
    comp.rows_scratch.deinit(gpa);
    comp.diagnostics.deinit(gpa);
    comp.reported.deinit(gpa);
    comp.stack.deinit(gpa);
    comp.arena.deinit();
    comp.* = undefined;
}

// the driver

/// Check one program from its root file, whose source the compilation takes
/// over. Every top-level declaration is analyzed, and every body that can be
/// checked without an instantiation is checked.
pub fn compile(comp: *Compilation, root_source: Source) Allocator.Error!void {
    assert(comp.modules.items.len == 0);

    const in_std = comp.std_dir != null and pathInside(comp.std_dir.?, comp.root_dir);
    const space: Module.Space = if (in_std) .std else .root;
    const key = try comp.fmt("{t}:{s}", .{ space, comp.root_stem });

    const index = try Module.register(comp, key, space, root_source);
    assert(index == .root);
    const module = comp.modules.items[index.int()];
    if (module.failed) return;

    const decls_end = module.decls_start + module.decls_len;
    for (module.decls_start..decls_end) |raw| {
        const decl_index: Decl.Index = @enumFromInt(@as(u32, @intCast(raw)));
        const decl = comp.decls.items[decl_index.int()];
        if (decl.owner != .none) continue;

        const origin: Origin = .{ .module = index, .node = decl.node };
        try comp.ensure(.forDecl(decl_index), origin);
        try comp.ensureBodies(decl_index, origin);
    }
    assert(comp.stack.items.len == 0);
    assert(comp.depth == 0);
}

/// Check the bodies a declaration carries where no instantiation is needed.
/// That is a plain function, and the plain methods of a plain struct.
fn ensureBodies(comp: *Compilation, decl_index: Decl.Index, origin: Origin) Allocator.Error!void {
    const decl = comp.decls.items[decl_index.int()];
    switch (decl.kind) {
        .use, .type_alias, .let => {},
        .fn_decl => try comp.ensureBodiesFn(decl_index, origin),
        .struct_decl => {
            if (decl.state != .done) return;
            if (comp.isGeneric(decl_index)) return;
            const members = decl.members();
            for (members.start..members.start + members.len) |raw| {
                const member: Decl.Index = @enumFromInt(@as(u32, @intCast(raw)));
                try comp.ensureBodiesFn(member, origin);
            }
        },
    }
}

fn ensureBodiesFn(comp: *Compilation, decl_index: Decl.Index, origin: Origin) Allocator.Error!void {
    const decl = comp.decls.items[decl_index.int()];
    if (decl.kind != .fn_decl) return;
    if (decl.state == .poisoned) return;
    if (comp.isGeneric(decl_index)) return;
    if (decl.builtin() != null) return;

    const instance = try comp.instantiate(decl_index, &.{});
    try comp.ensure(.of(.signature, instance), origin);
    try comp.ensure(.of(.body, instance), origin);
}

/// Whether a declaration takes type parameters of its own, or belongs to a
/// struct that does, so it only means something once instantiated.
pub fn isGeneric(comp: *const Compilation, decl_index: Decl.Index) bool {
    const decl = comp.decls.items[decl_index.int()];
    const tree = &comp.modules.items[decl.module.int()].tree;
    const own = switch (tree.viewOf(decl.node)) {
        .struct_decl => |view| view.type_params.len,
        .fn_decl => |view| view.type_params.len,
        else => 0,
    };
    if (own > 0) return true;
    if (decl.owner.unwrap()) |owner| return comp.isGeneric(owner);
    return false;
}

// ensure, the one door into every memoized computation

pub fn ensure(comp: *Compilation, unit: Unit, origin: Origin) Allocator.Error!void {
    switch (comp.unitState(unit)) {
        .done, .poisoned => return,
        .in_progress => {
            // calling a function being checked is recursion, not a cycle,
            // because its signature is already everything a call needs
            if (unit.kind == .body) return;
            return comp.reportCycle(unit, origin);
        },
        .unanalyzed => {},
    }

    // analysis recurses through whatever it demands, so even a chain of
    // plain declarations carries a bound
    if (comp.stack.items.len >= analyze_max) {
        try comp.reportNode(origin.module, origin.node, .{
            .code = .analysis_too_deep,
            .message = try comp.fmt(
                "checking this follows a chain more than {d} declarations deep",
                .{analyze_max},
            ),
            .label = "the chain stops here",
            .help = "a definition this far down a dependency chain is past what " ++
                "the compiler follows",
        });
        comp.setUnitState(unit, .poisoned);
        return;
    }

    // only a real instantiation, a unit with bracket arguments, counts
    // against the instantiation limit
    const instantiates = comp.unitIsInstantiation(unit);
    if (instantiates) {
        if (comp.instance_depth >= instantiate_max) {
            try comp.reportNode(origin.module, origin.node, .{
                .code = .instantiates_too_deep,
                .message = try comp.fmt("this instantiates more than {d} levels deep", .{
                    instantiate_max,
                }),
                .label = "the limit is here",
                .help = "a type or function that instantiates itself never bottoms out",
            });
            comp.setUnitState(unit, .poisoned);
            return;
        }
        comp.instance_depth += 1;
    }
    defer if (instantiates) {
        comp.instance_depth -= 1;
    };

    comp.setUnitState(unit, .in_progress);
    try comp.stack.append(comp.gpa, .{ .unit = unit, .origin = origin });
    defer _ = comp.stack.pop();

    const ok = switch (unit.kind) {
        .decl => try comp.runDecl(@enumFromInt(unit.index)),
        .rows => try Check.structRows(comp, @enumFromInt(unit.index)),
        .size => try Check.structSize(comp, @enumFromInt(unit.index)),
        .signature => try Check.fnSignature(comp, @enumFromInt(unit.index)),
        .body => try Check.fnBody(comp, @enumFromInt(unit.index)),
    };
    comp.setUnitState(unit, if (ok) .done else .poisoned);
}

fn runDecl(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    const decl = comp.decls.items[decl_index.int()];
    switch (decl.kind) {
        .use => return Module.resolveUse(comp, decl_index),
        .type_alias => return Check.typeAlias(comp, decl_index),
        .let => return Check.topLevelLet(comp, decl_index),
        .fn_decl => return true,
        .struct_decl => {
            if (comp.isGeneric(decl_index)) return true;
            const instance = try comp.instantiate(decl_index, &.{});
            const origin: Origin = .{ .module = decl.module, .node = decl.node };
            try comp.ensure(.of(.rows, instance), origin);
            try comp.ensure(.of(.size, instance), origin);
            return true;
        },
    }
}

fn unitState(comp: *const Compilation, unit: Unit) Decl.State {
    return switch (unit.kind) {
        .decl => comp.decls.items[unit.index].state,
        .rows, .signature => comp.instances.items[unit.index].rows_state,
        .size, .body => comp.instances.items[unit.index].deep_state,
    };
}

fn setUnitState(comp: *Compilation, unit: Unit, state: Decl.State) void {
    switch (unit.kind) {
        .decl => comp.decls.items[unit.index].state = state,
        .rows, .signature => comp.instances.items[unit.index].rows_state = state,
        .size, .body => comp.instances.items[unit.index].deep_state = state,
    }
}

/// A re-entry is a cycle. The report lands on the reference that closed it,
/// and the chain back to the definition becomes the notes.
fn reportCycle(comp: *Compilation, unit: Unit, origin: Origin) Allocator.Error!void {
    @branchHint(.cold);

    const message = switch (unit.kind) {
        .decl => switch (comp.decls.items[unit.index].kind) {
            .let => try comp.fmt("'{s}' takes its value from itself", .{comp.unitName(unit)}),
            .type_alias => try comp.fmt("type '{s}' is an alias of itself", .{
                comp.unitName(unit),
            }),
            .use => "this import goes in a circle",
            .struct_decl, .fn_decl => "this definition goes in a circle",
        },
        .size => try comp.fmt("'{s}' holds itself by value, so it has no size", .{
            comp.unitName(unit),
        }),
        .rows, .signature, .body => "this definition goes in a circle",
    };
    const help: ?[]const u8 = switch (unit.kind) {
        .size => try comp.fmt("break the cycle with a pointer: '*{s}' or '?*{s}'", .{
            comp.unitName(unit), comp.unitName(unit),
        }),
        else => null,
    };

    // the frames past the unit's own are the chain that led back to it
    var position: usize = comp.stack.items.len;
    for (comp.stack.items, 0..) |frame, at| {
        if (frame.unit.eql(unit)) {
            position = at;
            break;
        }
    }
    assert(position < comp.stack.items.len);

    var chain: std.ArrayList(Diagnostic.Note) = .empty;
    defer chain.deinit(comp.gpa);
    for (comp.stack.items[position + 1 ..]) |frame| {
        try chain.append(comp.gpa, comp.noteAt(
            frame.origin.module,
            frame.origin.node,
            try comp.fmt("which needs '{s}' here", .{comp.unitName(frame.unit)}),
        ));
    }

    try comp.reportNode(origin.module, origin.node, .{
        .code = if (unit.kind == .size) .size_cycle else .value_cycle,
        .message = message,
        .label = "the circle closes here",
        .help = help,
        .notes = try comp.notes(chain.items),
    });
}

fn unitName(comp: *Compilation, unit: Unit) []const u8 {
    switch (unit.kind) {
        .decl => {
            const decl = comp.decls.items[unit.index];
            return comp.pool.stringText(decl.name);
        },
        else => {
            const instance: Pool.Instance = @enumFromInt(unit.index);
            var out: Writer.Allocating = .init(comp.arena.allocator());
            comp.spellInstance(&out.writer, instance) catch return "?";
            return out.written();
        },
    }
}

// instantiation, where one memo table makes identity the row

pub fn instantiate(
    comp: *Compilation,
    decl_index: Decl.Index,
    args: []const Pool.Index,
) Allocator.Error!Pool.Instance {
    const decl = comp.decls.items[decl_index.int()];
    assert(decl.kind == .struct_decl or decl.kind == .fn_decl);

    const gop = try comp.instance_map.getOrPutContextAdapted(
        comp.gpa,
        InstanceKey{ .decl = decl_index, .args = args },
        InstanceKeyAdapter{ .comp = comp },
        InstanceIndexContext{ .comp = comp },
    );
    if (gop.found_existing) return gop.key_ptr.*;

    if (comp.instances.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const index: Pool.Instance = @enumFromInt(@as(u32, @intCast(comp.instances.items.len)));

    const args_start: u32 = @intCast(comp.instance_args.items.len);
    try comp.instance_args.appendSlice(comp.gpa, args);
    try comp.instances.append(comp.gpa, .{
        .decl = decl_index,
        .args_start = args_start,
        .args_len = @intCast(args.len),
        .type = .poison,
        .rows_start = 0,
        .rows_len = 0,
        .func = .none,
        .rows_state = .unanalyzed,
        .deep_state = .unanalyzed,
    });
    gop.key_ptr.* = index;

    // a struct instantiation is a type the moment it exists, fields or not,
    // which is what lets a struct name itself
    if (decl.kind == .struct_decl) {
        comp.instances.items[index.int()].type = try comp.pool.intern(comp.gpa, .{
            .struct_type = index,
        });
    }
    return index;
}

pub fn instanceArgs(comp: *const Compilation, index: Pool.Instance) []const Pool.Index {
    const instance = comp.instances.items[index.int()];
    return comp.instance_args.items[instance.args_start..][0..instance.args_len];
}

pub fn instanceRows(comp: *const Compilation, index: Pool.Instance) []const Row {
    const instance = comp.instances.items[index.int()];
    return comp.rows.items[instance.rows_start..][0..instance.rows_len];
}

const InstanceKey = struct { decl: Decl.Index, args: []const Pool.Index };

const InstanceKeyAdapter = struct {
    comp: *const Compilation,

    pub fn hash(_: InstanceKeyAdapter, key: InstanceKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.decl));
        hasher.update(std.mem.sliceAsBytes(key.args));
        return hasher.final();
    }

    pub fn eql(adapter: InstanceKeyAdapter, key: InstanceKey, index: Pool.Instance) bool {
        const instance = adapter.comp.instances.items[index.int()];
        if (instance.decl != key.decl) return false;
        return std.mem.eql(Pool.Index, key.args, adapter.comp.instanceArgs(index));
    }
};

const InstanceIndexContext = struct {
    comp: *const Compilation,

    pub fn hash(context: InstanceIndexContext, index: Pool.Instance) u64 {
        const instance = context.comp.instances.items[index.int()];
        return (InstanceKeyAdapter{ .comp = context.comp }).hash(.{
            .decl = instance.decl,
            .args = context.comp.instanceArgs(index),
        });
    }

    pub fn eql(_: InstanceIndexContext, a: Pool.Instance, b: Pool.Instance) bool {
        return a == b;
    }
};

/// Bounded Levenshtein distance, enough to rank a typo. Long names are cut
/// off, since a suggestion past forty characters convinces nobody.
pub fn editDistance(a: []const u8, b: []const u8) u32 {
    const cap = 40;
    const from = a[0..@min(a.len, cap)];
    const to = b[0..@min(b.len, cap)];

    var row: [cap + 1]u32 = undefined;
    for (0..to.len + 1) |column| row[column] = @intCast(column);

    for (from, 1..) |byte, at| {
        var corner = row[0];
        row[0] = @intCast(at);
        for (to, 1..) |other, column| {
            const cost: u32 = if (byte == other) 0 else 1;
            const replaced = corner + cost;
            const inserted = row[column - 1] + 1;
            const removed = row[column] + 1;
            corner = row[column];
            row[column] = @min(replaced, @min(inserted, removed));
        }
    }
    return row[to.len];
}

// the report path, which every diagnostic analysis produces goes through

pub const Report = struct {
    code: Diagnostic.Code,
    message: []const u8,
    label: []const u8 = "",
    help: ?[]const u8 = null,
    notes: []const Diagnostic.Note = &.{},
};

pub fn reportNode(
    comp: *Compilation,
    module: Module.Index,
    node: AST.Node.Index,
    report_value: Report,
) Allocator.Error!void {
    @branchHint(.cold);
    const tree = &comp.modules.items[module.int()].tree;
    try comp.report(module, tree.nodeSpan(node), report_value);
}

pub fn reportToken(
    comp: *Compilation,
    module: Module.Index,
    token: Token.Index,
    report_value: Report,
) Allocator.Error!void {
    @branchHint(.cold);
    const tree = &comp.modules.items[module.int()].tree;
    try comp.report(module, .{
        .start = tree.tokenStart(token),
        .end = tree.tokenEnd(token),
    }, report_value);
}

pub fn report(
    comp: *Compilation,
    module: Module.Index,
    span: Diagnostic.Span,
    report_value: Report,
) Allocator.Error!void {
    @branchHint(.cold);
    assert(report_value.message.len > 0);
    assert(span.start <= span.end);

    // one mistake, one report. re-emitted defers and repeated instantiations
    // land on the same spot and are dropped here
    const key: ReportKey = .{ .module = module, .code = report_value.code, .offset = span.start };
    const seen = try comp.reported.getOrPut(comp.gpa, key);
    if (seen.found_existing) return;
    if (comp.diagnostics.items.len >= diagnostics_max) return;

    try comp.diagnostics.append(comp.gpa, .{
        .module = module,
        .diagnostic = .{
            .code = report_value.code,
            .span = span,
            .message = report_value.message,
            .label = report_value.label,
            .help = report_value.help,
            .notes = try comp.withTrail(report_value.notes),
        },
    });
}

/// The instantiation trail, appended to whatever notes a report carries, so
/// no reporting site can forget it.
fn withTrail(
    comp: *Compilation,
    notes_in: []const Diagnostic.Note,
) Allocator.Error![]Diagnostic.Note {
    const trail_cap = 8;

    var generic_frames: u32 = 0;
    for (comp.stack.items) |frame| {
        if (comp.unitIsInstantiation(frame.unit)) generic_frames += 1;
    }

    const shown = @min(generic_frames, trail_cap);
    const extra: u32 = if (generic_frames > trail_cap) 1 else 0;
    const total = notes_in.len + shown + extra;
    if (total == 0) return &.{};

    const out = try comp.arena.allocator().alloc(Diagnostic.Note, total);
    @memcpy(out[0..notes_in.len], notes_in);

    var at = notes_in.len;
    var used: u32 = 0;
    var index = comp.stack.items.len;
    while (index > 0 and used < shown) {
        index -= 1;
        const frame = comp.stack.items[index];
        if (comp.unitIsInstantiation(frame.unit) == false) continue;
        out[at] = comp.noteAt(
            frame.origin.module,
            frame.origin.node,
            try comp.fmt("while checking '{s}', needed here", .{comp.unitName(frame.unit)}),
        );
        at += 1;
        used += 1;
    }
    if (extra == 1) {
        out[at] = .{ .message = try comp.fmt("and {d} more instantiation levels", .{
            generic_frames - trail_cap,
        }) };
        at += 1;
    }
    assert(at == total);
    return out;
}

/// Whether a unit carries bracket arguments. The instantiation limit and the
/// diagnostic trail both key on exactly this.
fn unitIsInstantiation(comp: *const Compilation, unit: Unit) bool {
    switch (unit.kind) {
        .decl => return false,
        .rows, .size, .signature, .body => {
            return comp.instances.items[unit.index].args_len > 0;
        },
    }
}

pub fn noteAt(
    comp: *Compilation,
    module: Module.Index,
    node: AST.Node.Index,
    message: []const u8,
) Diagnostic.Note {
    const owner = comp.modules.items[module.int()];
    return .{
        .message = message,
        .span = owner.tree.nodeSpan(node),
        .source = &owner.source,
    };
}

pub fn notes(comp: *Compilation, list: []const Diagnostic.Note) Allocator.Error![]Diagnostic.Note {
    return comp.arena.allocator().dupe(Diagnostic.Note, list);
}

pub fn fmt(
    comp: *Compilation,
    comptime template: []const u8,
    args: anytype,
) Allocator.Error![]const u8 {
    comptime assert(template.len > 0);
    return std.fmt.allocPrint(comp.arena.allocator(), template, args);
}

pub fn renderAll(comp: *Compilation, writer: *Writer, color: Diagnostic.Color) !void {
    assert(comp.diagnostics.items.len > 0);
    for (comp.diagnostics.items) |entry| {
        const module = comp.modules.items[entry.module.int()];
        try entry.diagnostic.render(comp.gpa, &module.source, writer, color);
    }
}

pub fn dumpIR(comp: *const Compilation, writer: *Writer) Writer.Error!void {
    for (comp.funcs.items, 0..) |*func, index| {
        if (index > 0) try writer.writeByte('\n');
        try IR.dump(comp, func, writer);
    }
}

// spelling, how a diagnostic or a dump names what the tables hold

pub fn spellType(comp: *const Compilation, writer: *Writer, index: Pool.Index) Writer.Error!void {
    var current = index;
    var depth: u32 = 0;
    const depth_cap = 64;

    while (depth < depth_cap) : (depth += 1) {
        switch (comp.pool.keyOf(current)) {
            .simple => |simple| return switch (simple) {
                .poison => writer.writeAll("<broken>"),
                .untyped_int => writer.writeAll("an untyped number"),
                .untyped_float => writer.writeAll("an untyped float"),
                .@"error" => writer.writeAll("an error"),
                .nothing => writer.writeAll("nothing"),
                else => writer.writeAll(@tagName(simple)),
            },
            .pointer => |pointer| {
                try writer.writeAll(if (pointer.mutable) "*var " else "*");
                current = pointer.child;
            },
            .optional => |child| {
                try writer.writeByte('?');
                current = child;
            },
            .error_union => |child| {
                try writer.writeByte('!');
                current = child;
            },
            .struct_type => |instance| return comp.spellInstance(writer, instance),
            .int, .float, .error_value, .null_typed => unreachable,
        }
    }
    try writer.writeAll("...");
}

/// `Box[i64]`, declaration plus arguments, canonically, with the owner in
/// front for a member, as in `Arena.copy[Pair]`.
pub fn spellInstance(
    comp: *const Compilation,
    writer: *Writer,
    index: Pool.Instance,
) Writer.Error!void {
    const instance = comp.instances.items[index.int()];
    const decl = comp.decls.items[instance.decl.int()];
    const args = comp.instanceArgs(index);

    var skip: usize = 0;
    if (decl.owner.unwrap()) |owner_index| {
        const owner = comp.decls.items[owner_index.int()];
        try writer.writeAll(comp.pool.stringText(owner.name));
        // the owner's parameters lead the argument list. spell them as its own
        const owner_params = comp.typeParamCount(owner_index);
        skip = @min(owner_params, args.len);
        try comp.spellArgs(writer, args[0..skip]);
        try writer.writeByte('.');
    }
    try writer.writeAll(comp.pool.stringText(decl.name));
    try comp.spellArgs(writer, args[skip..]);
}

fn spellArgs(
    comp: *const Compilation,
    writer: *Writer,
    args: []const Pool.Index,
) Writer.Error!void {
    if (args.len == 0) return;
    try writer.writeByte('[');
    for (args, 0..) |arg, position| {
        if (position > 0) try writer.writeAll(", ");
        if (comp.pool.isType(arg)) {
            try comp.spellType(writer, arg);
        } else {
            try comp.spellConstant(writer, arg);
        }
    }
    try writer.writeByte(']');
}

/// `(a: i64, b: bool) i64` from a resolved signature, for the IR header.
pub fn spellSignature(
    comp: *const Compilation,
    writer: *Writer,
    index: Pool.Instance,
) Writer.Error!void {
    const instance = comp.instances.items[index.int()];
    assert(instance.rows_state == .done or instance.rows_state == .poisoned);

    try writer.writeByte('(');
    for (comp.instanceRows(index), 0..) |row, position| {
        if (position > 0) try writer.writeAll(", ");
        try writer.print("{s}: ", .{comp.pool.stringText(row.name)});
        try comp.spellType(writer, row.type);
    }
    try writer.writeByte(')');
    if (instance.type != .nothing_type) {
        try writer.writeByte(' ');
        try comp.spellType(writer, instance.type);
    }
}

pub fn spellConstant(
    comp: *const Compilation,
    writer: *Writer,
    value: Pool.Index,
) Writer.Error!void {
    switch (comp.pool.keyOf(value)) {
        .simple => |simple| switch (simple) {
            .poison => try writer.writeAll("<broken>"),
            .true => try writer.writeAll("true"),
            .false => try writer.writeAll("false"),
            .null => try writer.writeAll("null"),
            else => unreachable,
        },
        .int => |it| {
            try writer.print("{d}", .{it.value});
            if (it.type != .untyped_int_type) {
                try writer.writeByte(':');
                try comp.spellType(writer, it.type);
            }
        },
        .float => |it| {
            try writer.print("{d}", .{it.value});
            if (it.type != .untyped_float_type) {
                try writer.writeByte(':');
                try comp.spellType(writer, it.type);
            }
        },
        .error_value => |name| try writer.print("error.{s}", .{comp.pool.stringText(name)}),
        .null_typed => try writer.writeAll("null"),
        .pointer, .optional, .error_union, .struct_type => unreachable,
    }
}

/// A constant's value alone, for a message naming what did not fit.
pub fn spellValue(comp: *Compilation, value: Pool.Index) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(comp.arena.allocator());
    comp.spellConstantBare(&out.writer, value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.written();
}

fn spellConstantBare(
    comp: *const Compilation,
    writer: *Writer,
    value: Pool.Index,
) Writer.Error!void {
    switch (comp.pool.keyOf(value)) {
        .int => |it| try writer.print("{d}", .{it.value}),
        .float => |it| try writer.print("{d}", .{it.value}),
        else => try comp.spellConstant(writer, value),
    }
}

/// The name a message or a dump uses for a type, in the diagnostic arena.
pub fn typeName(comp: *Compilation, index: Pool.Index) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(comp.arena.allocator());
    comp.spellType(&out.writer, index) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.written();
}

pub fn rowName(comp: *const Compilation, row: u32) []const u8 {
    assert(row < comp.rows.items.len);
    return comp.pool.stringText(comp.rows.items[row].name);
}

pub fn typeParamCount(comp: *const Compilation, decl_index: Decl.Index) usize {
    const decl = comp.decls.items[decl_index.int()];
    const tree = &comp.modules.items[decl.module.int()].tree;
    return switch (tree.viewOf(decl.node)) {
        .struct_decl => |view| view.type_params.len,
        .fn_decl => |view| view.type_params.len,
        else => 0,
    };
}

// the universal scope

const universal = std.StaticStringMap(Pool.Index).initComptime(.{
    .{ "bool", .bool_type },
    .{ "i8", .i8_type },
    .{ "i16", .i16_type },
    .{ "i32", .i32_type },
    .{ "i64", .i64_type },
    .{ "u8", .u8_type },
    .{ "u16", .u16_type },
    .{ "u32", .u32_type },
    .{ "u64", .u64_type },
    .{ "f32", .f32_type },
    .{ "f64", .f64_type },
});

/// One name per type, and no synonyms. This is the whole universal scope.
pub fn universalType(comp: *const Compilation, name: Pool.String) ?Pool.Index {
    return universal.get(comp.pool.stringText(name));
}

pub fn universalTypeText(text: []const u8) ?Pool.Index {
    return universal.get(text);
}

/// Whether one path sits inside another, textually. Enough to notice the root
/// file being checked inside the standard library itself.
fn pathInside(outer: []const u8, inner: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, outer, "/");
    if (std.mem.startsWith(u8, inner, trimmed) == false) return false;
    if (inner.len == trimmed.len) return true;
    return inner[trimmed.len] == '/';
}

// testing

const testing = std.testing;

fn testSource(gpa: Allocator, text: []const u8) Allocator.Error!Source {
    const buffer = try gpa.alloc(u8, text.len + Source.padding);
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    return .{ .path = "test.nul", .bytes = buffer[0..text.len :0] };
}

test "instantiation identity is index equality" {
    const gpa = testing.allocator;

    var comp: Compilation = undefined;
    try comp.init(gpa, testing.io, .{ .root_path = "test.nul", .std_dir = null });
    defer comp.deinit();

    try comp.compile(try testSource(gpa,
        \\pub struct Box[T] {
        \\    item: T
        \\}
        \\pub type Boxed = Box[i64]
        \\fn hold(a: Box[i64], b: Boxed, c: Box[u8]) Boxed {
        \\    return a
        \\}
        \\
    ));
    try testing.expectEqual(0, comp.diagnostics.items.len);

    const hold = comp.modules.items[0].findDecl(try comp.pool.string(gpa, "hold")).?;
    const instance = try comp.instantiate(hold, &.{});
    const rows = comp.instanceRows(instance);
    try testing.expectEqual(3, rows.len);

    // `Box[i64]` written twice, and once through an alias. one index
    try testing.expectEqual(rows[0].type, rows[1].type);
    try testing.expectEqual(rows[1].type, comp.instances.items[instance.int()].type);
    // `Box[u8]` is another type entirely
    try testing.expect(rows[0].type != rows[2].type);
}

test "plain depth is bounded by the budget, not the instantiation limit" {
    const gpa = testing.allocator;

    var deep: Writer.Allocating = .init(gpa);
    defer deep.deinit();
    for (0..90) |level| {
        try deep.writer.print("fn g{d}(n: i64) i64 {{ return g{d}(n) }}\n", .{
            level, level + 1,
        });
    }
    try deep.writer.writeAll("fn g90(n: i64) i64 { return n }\n");

    var comp: Compilation = undefined;
    try comp.init(gpa, testing.io, .{ .root_path = "test.nul", .std_dir = null });
    defer comp.deinit();
    try comp.compile(try testSource(gpa, deep.written()));
    try testing.expectEqual(0, comp.diagnostics.items.len);
}

test "the analysis budget reports once instead of overflowing the stack" {
    const gpa = testing.allocator;

    var adversary: Writer.Allocating = .init(gpa);
    defer adversary.deinit();
    for (0..60) |level| {
        try adversary.writer.print("fn g{d}(n: i64) i64 {{ return ", .{level});
        try adversary.writer.splatBytesAll("(1 + ", 50);
        try adversary.writer.print("g{d}(n)", .{level + 1});
        try adversary.writer.splatBytesAll(")", 50);
        try adversary.writer.writeAll(" }\n");
    }
    try adversary.writer.writeAll("fn g60(n: i64) i64 { return n }\n");

    var comp: Compilation = undefined;
    try comp.init(gpa, testing.io, .{ .root_path = "test.nul", .std_dir = null });
    defer comp.deinit();
    try comp.compile(try testSource(gpa, adversary.written()));

    var reported: u32 = 0;
    for (comp.diagnostics.items) |entry| {
        if (entry.diagnostic.code == .analysis_too_deep) reported += 1;
    }
    try testing.expectEqual(1, reported);
}

test "a diagnostic renders across files" {
    const gpa = testing.allocator;

    var comp: Compilation = undefined;
    try comp.init(gpa, testing.io, .{ .root_path = "test.nul", .std_dir = null });
    defer comp.deinit();

    try comp.compile(try testSource(gpa,
        \\fn f() i64 {
        \\    return missing
        \\}
        \\
    ));
    try testing.expectEqual(1, comp.diagnostics.items.len);

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try comp.renderAll(&out.writer, .off);
    try testing.expect(std.mem.indexOf(u8, out.written(), "nothing named 'missing'") != null);
}
