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
const dump = @import("util/dump.zig");
const spell = @import("util/spell.zig");

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
/// Parameters and fields share one shape, so one table. An instance holds a
/// contiguous range.
rows: std.ArrayList(Row),
/// Marked and restored, because one signature can demand another.
rows_scratch: std.ArrayList(Row),
funcs: std.ArrayList(IR.Func),
diagnostics: std.ArrayList(Entry),
/// One row per (module, code, offset), so re-walked code reports once.
reported: std.AutoHashMapUnmanaged(ReportKey, void),

// transient analysis state

/// What is being analyzed, the cycle chain, and the trail.
stack: std.ArrayList(Frame),
/// Frames on the stack that are instantiations, capped at `instantiate_max`.
instance_depth: u32,
/// Backs diagnostic text, module keys, and paths until deinit.
arena: std.heap.ArenaAllocator,

// configuration

/// Directory of the root file. Bare module paths resolve against it.
root_dir: []const u8,
/// Stem of the root file, its name if something imports it back.
root_stem: []const u8,
/// Where `std.` resolves, or null.
std_dir: ?[]const u8,

const Compilation = @This();

pub const instantiate_max = 64;
pub const analyze_max = 128;
const diagnostics_max = 256;

/// A declaration plus its bracket arguments, memoized so identity is the row.
pub const Instance = struct {
    decl: Decl.Index,
    args: Range,
    /// A struct type, or a function return type once resolved.
    type: Pool.Index,
    /// Fields for a struct, parameters for a function.
    rows: Range,
    /// Fields resolved, or signature resolved.
    rows_state: Decl.State,
    /// The embedding walk, or the body check.
    deep_state: Decl.State,
};

/// A contiguous run in a table.
pub const Range = struct {
    start: u32,
    len: u32,

    pub const empty: Range = .{ .start = 0, .len = 0 };

    pub fn end(range: Range) u32 {
        return range.start + range.len;
    }

    pub fn at(range: Range, position: u32) u32 {
        assert(position < range.len);
        return range.start + position;
    }
};

/// A parameter or a field.
pub const Row = struct {
    name: Pool.String,
    type: Pool.Index,
    node: AST.Node.Index,
};

/// One memoized computation, runnable only through `ensure`.
pub const Unit = struct {
    kind: Kind,
    index: u32,

    pub const Kind = enum(u8) { decl, rows, embedding, signature, body };

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

/// Where a demand came from, named by a cycle report or the trail.
pub const Origin = struct { module: Module.Index, node: AST.Node.Index };

const Frame = struct { unit: Unit, origin: Origin };

const ReportKey = struct { module: Module.Index, code: Diagnostic.Code, offset: u32 };

pub const Entry = struct { module: Module.Index, diagnostic: Diagnostic };

pub const Options = struct {
    root_path: []const u8,
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

/// Check one program from its root file, whose source this takes over.
pub fn compile(comp: *Compilation, root_source: Source) Allocator.Error!void {
    assert(comp.modules.items.len == 0);

    const in_std = comp.std_dir != null and pathInside(comp.std_dir.?, comp.root_dir);
    const space: Module.Space = if (in_std) .std else .root;
    const key = try comp.fmt("{t}:{s}", .{ space, comp.root_stem });

    const index = try Module.register(comp, key, space, root_source);
    assert(index == .root);
    const module = comp.moduleAt(index);
    if (module.failed) return;

    for (module.decls.start..module.decls.end()) |raw| {
        const decl_index: Decl.Index = .from(raw);
        const decl = comp.declAt(decl_index);
        if (decl.owner != .none) continue;

        const origin: Origin = .{ .module = index, .node = decl.node };
        try comp.ensure(.forDecl(decl_index), origin);
        try comp.ensureBodies(decl_index, origin);
    }
    assert(comp.stack.items.len == 0);
}

/// A plain function, and the plain methods of a plain struct.
fn ensureBodies(comp: *Compilation, decl_index: Decl.Index, origin: Origin) Allocator.Error!void {
    const decl = comp.declAt(decl_index);
    switch (decl.kind) {
        .import, .type_alias, .let => {},
        .fn_decl => try comp.ensureBodiesFn(decl_index, origin),
        .struct_decl => {
            if (decl.state != .done) return;
            if (comp.isGeneric(decl_index)) return;
            const members = decl.members();
            for (members.start..members.start + members.len) |raw| {
                const member: Decl.Index = .from(raw);
                try comp.ensureBodiesFn(member, origin);
            }
        },
    }
}

fn ensureBodiesFn(comp: *Compilation, decl_index: Decl.Index, origin: Origin) Allocator.Error!void {
    const decl = comp.declAt(decl_index);
    if (decl.kind != .fn_decl) return;
    if (decl.state == .poisoned) return;
    if (comp.isGeneric(decl_index)) return;

    const instance = try comp.instantiate(decl_index, &.{});
    try comp.ensure(.of(.signature, instance), origin);
    try comp.ensure(.of(.body, instance), origin);
}

/// Whether a declaration only means something once instantiated.
pub fn isGeneric(comp: *const Compilation, decl_index: Decl.Index) bool {
    const decl = comp.declAt(decl_index);
    if (comp.typeParamCount(decl_index) > 0) return true;
    if (decl.owner.unwrap()) |owner| return comp.isGeneric(owner);
    return false;
}

// ensure, the one door into every memoized computation

pub fn ensure(comp: *Compilation, unit: Unit, origin: Origin) Allocator.Error!void {
    switch (comp.unitState(unit)) {
        .done, .poisoned => return,
        .in_progress => {
            // recursion, not a cycle. a signature is all a call needs
            if (unit.kind == .body) return;
            return comp.reportCycle(unit, origin);
        },
        .unanalyzed => {},
    }

    // analysis recurses through whatever it demands
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

    // only bracket arguments count against the instantiation limit
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
        .embedding => try Check.structEmbedding(comp, @enumFromInt(unit.index)),
        .signature => try Check.fnSignature(comp, @enumFromInt(unit.index)),
        .body => try Check.fnBody(comp, @enumFromInt(unit.index)),
    };
    comp.setUnitState(unit, if (ok) .done else .poisoned);
}

fn runDecl(comp: *Compilation, decl_index: Decl.Index) Allocator.Error!bool {
    const decl = comp.declAt(decl_index);
    switch (decl.kind) {
        .import => return Module.resolveImport(comp, decl_index),
        .type_alias => return Check.typeAlias(comp, decl_index),
        .let => return Check.topLevelLet(comp, decl_index),
        .fn_decl => return true,
        .struct_decl => {
            if (comp.isGeneric(decl_index)) return true;
            const instance = try comp.instantiate(decl_index, &.{});
            const origin: Origin = .{ .module = decl.module, .node = decl.node };
            try comp.ensure(.of(.rows, instance), origin);
            try comp.ensure(.of(.embedding, instance), origin);
            return true;
        },
    }
}

fn unitState(comp: *const Compilation, unit: Unit) Decl.State {
    return switch (unit.kind) {
        .decl => comp.declAt(@enumFromInt(unit.index)).state,
        .rows, .signature => comp.instanceAt(@enumFromInt(unit.index)).rows_state,
        .embedding, .body => comp.instanceAt(@enumFromInt(unit.index)).deep_state,
    };
}

fn setUnitState(comp: *Compilation, unit: Unit, state: Decl.State) void {
    switch (unit.kind) {
        .decl => comp.declPtr(@enumFromInt(unit.index)).state = state,
        .rows, .signature => comp.instancePtr(@enumFromInt(unit.index)).rows_state = state,
        .embedding, .body => comp.instancePtr(@enumFromInt(unit.index)).deep_state = state,
    }
}

/// A re-entry is a cycle. The chain back becomes the notes.
fn reportCycle(comp: *Compilation, unit: Unit, origin: Origin) Allocator.Error!void {
    @branchHint(.cold);

    const name = try comp.unitName(unit);
    const message = switch (unit.kind) {
        .decl => switch (comp.declAt(@enumFromInt(unit.index)).kind) {
            .let => try comp.fmt("'{s}' takes its value from itself", .{name}),
            .type_alias => try comp.fmt("type '{s}' is an alias of itself", .{name}),
            .import => "this import goes in a circle",
            .struct_decl, .fn_decl => "this definition goes in a circle",
        },
        .embedding => try comp.fmt("'{s}' holds itself by value, so it has no size", .{name}),
        .rows, .signature, .body => "this definition goes in a circle",
    };
    const help: ?[]const u8 = switch (unit.kind) {
        .embedding => try comp.fmt("break the cycle with a pointer: '*{s}'", .{name}),
        else => null,
    };

    // the frames above this unit are the chain back to it
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
            try comp.fmt("which needs '{s}' here", .{try comp.unitName(frame.unit)}),
        ));
    }

    try comp.reportNode(origin.module, origin.node, .{
        .code = if (unit.kind == .embedding) .size_cycle else .value_cycle,
        .message = message,
        .label = "the circle closes here",
        .help = help,
        .notes = try comp.notes(chain.items),
    });
}

fn unitName(comp: *Compilation, unit: Unit) Allocator.Error![]const u8 {
    switch (unit.kind) {
        .decl => {
            const decl = comp.declAt(@enumFromInt(unit.index));
            return comp.pool.stringText(decl.name);
        },
        else => return comp.instanceName(@enumFromInt(unit.index)),
    }
}

// instantiation, where one memo table makes identity the row

pub fn instantiate(
    comp: *Compilation,
    decl_index: Decl.Index,
    args: []const Pool.Index,
) Allocator.Error!Pool.Instance {
    const decl = comp.declAt(decl_index);
    assert(decl.kind == .struct_decl or decl.kind == .fn_decl);

    const gop = try comp.instance_map.getOrPutContextAdapted(
        comp.gpa,
        InstanceKey{ .decl = decl_index, .args = args },
        InstanceKeyAdapter{ .comp = comp },
        InstanceIndexContext{ .comp = comp },
    );
    if (gop.found_existing) return gop.key_ptr.*;

    if (comp.instances.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const index: Pool.Instance = .from(comp.instances.items.len);

    const args_start: u32 = @intCast(comp.instance_args.items.len);
    try comp.instance_args.appendSlice(comp.gpa, args);
    try comp.instances.append(comp.gpa, .{
        .decl = decl_index,
        .args = .{ .start = args_start, .len = @intCast(args.len) },
        .type = .poison,
        .rows = .empty,
        .rows_state = .unanalyzed,
        .deep_state = .unanalyzed,
    });
    gop.key_ptr.* = index;

    // a type the moment it exists, so a struct can name itself
    if (decl.kind == .struct_decl) {
        comp.instancePtr(index).type = try comp.pool.intern(comp.gpa, .{
            .type_struct = index,
        });
    }
    return index;
}

pub fn declAt(comp: *const Compilation, index: Decl.Index) Decl {
    assert(index.int() < comp.decls.items.len);
    return comp.decls.items[index.int()];
}

pub fn declPtr(comp: *Compilation, index: Decl.Index) *Decl {
    assert(index.int() < comp.decls.items.len);
    return &comp.decls.items[index.int()];
}

pub fn instanceAt(comp: *const Compilation, index: Pool.Instance) Instance {
    assert(index.int() < comp.instances.items.len);
    return comp.instances.items[index.int()];
}

pub fn instancePtr(comp: *Compilation, index: Pool.Instance) *Instance {
    assert(index.int() < comp.instances.items.len);
    return &comp.instances.items[index.int()];
}

pub fn moduleAt(comp: *const Compilation, index: Module.Index) *Module {
    assert(index.int() < comp.modules.items.len);
    return comp.modules.items[index.int()];
}

pub fn treeOf(comp: *const Compilation, index: Module.Index) *const AST {
    return &comp.moduleAt(index).tree;
}

pub fn rowAt(comp: *const Compilation, at: u32) Row {
    assert(at < comp.rows.items.len);
    return comp.rows.items[at];
}

pub fn instanceDecl(comp: *const Compilation, index: Pool.Instance) Decl.Index {
    return comp.instanceAt(index).decl;
}

/// A struct's type, or a resolved return type.
pub fn instanceType(comp: *const Compilation, index: Pool.Instance) Pool.Index {
    return comp.instanceAt(index).type;
}

pub fn ensureRows(comp: *Compilation, index: Pool.Instance) Allocator.Error!void {
    const decl = comp.declAt(comp.instanceDecl(index));
    try comp.ensure(.of(.rows, index), .{ .module = decl.module, .node = decl.node });
}

/// Invalidated by any other instantiation.
pub fn instanceArgs(comp: *const Compilation, index: Pool.Instance) []const Pool.Index {
    const instance = comp.instanceAt(index);
    return comp.instance_args.items[instance.args.start..][0..instance.args.len];
}

/// Fields, or signature parameters. Invalidated by any other commit.
pub fn instanceRows(comp: *const Compilation, index: Pool.Instance) []const Row {
    const instance = comp.instanceAt(index);
    return comp.rows.items[instance.rows.start..][0..instance.rows.len];
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
        const instance = adapter.comp.instanceAt(index);
        if (instance.decl != key.decl) return false;
        return std.mem.eql(Pool.Index, key.args, adapter.comp.instanceArgs(index));
    }
};

const InstanceIndexContext = struct {
    comp: *const Compilation,

    pub fn hash(context: InstanceIndexContext, index: Pool.Instance) u64 {
        const instance = context.comp.instanceAt(index);
        return (InstanceKeyAdapter{ .comp = context.comp }).hash(.{
            .decl = instance.decl,
            .args = context.comp.instanceArgs(index),
        });
    }

    pub fn eql(_: InstanceIndexContext, a: Pool.Instance, b: Pool.Instance) bool {
        return a == b;
    }
};

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
    const tree = comp.treeOf(module);
    try comp.report(module, tree.nodeSpan(node), report_value);
}

pub fn reportToken(
    comp: *Compilation,
    module: Module.Index,
    token: Token.Index,
    report_value: Report,
) Allocator.Error!void {
    @branchHint(.cold);
    const tree = comp.treeOf(module);
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

    // one mistake, one report, however often the spot is re-walked
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

/// Appended to every report, so no site can forget the trail.
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
            try comp.fmt("while checking '{s}', needed here", .{try comp.unitName(frame.unit)}),
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

/// Whether a unit carries bracket arguments.
fn unitIsInstantiation(comp: *const Compilation, unit: Unit) bool {
    switch (unit.kind) {
        .decl => return false,
        .rows, .embedding, .signature, .body => {
            return comp.instanceAt(@enumFromInt(unit.index)).args.len > 0;
        },
    }
}

pub fn noteAt(
    comp: *Compilation,
    module: Module.Index,
    node: AST.Node.Index,
    message: []const u8,
) Diagnostic.Note {
    const owner = comp.moduleAt(module);
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
        const module = comp.moduleAt(entry.module);
        try entry.diagnostic.render(comp.gpa, &module.source, writer, color);
    }
}

pub fn dumpIR(comp: *const Compilation, writer: *Writer) Writer.Error!void {
    for (comp.funcs.items, 0..) |*func, index| {
        if (index > 0) try writer.writeByte('\n');
        try dump.func(comp, func, writer);
    }
}

/// One of the `spell` writers into the diagnostic arena.
fn spelled(comp: *Compilation, writer: anytype, subject: anytype) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(comp.arena.allocator());
    writer(comp, &out.writer, subject) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.written();
}

pub fn typeName(comp: *Compilation, index: Pool.Index) Allocator.Error![]const u8 {
    return comp.spelled(spell.writeType, index);
}

pub fn instanceName(comp: *Compilation, index: Pool.Instance) Allocator.Error![]const u8 {
    return comp.spelled(spell.writeInstance, index);
}

/// The value alone, for a message naming what did not fit.
pub fn spellValue(comp: *Compilation, value: Pool.Index) Allocator.Error![]const u8 {
    return comp.spelled(spell.writeConstantBare, value);
}

pub fn rowName(comp: *const Compilation, row: u32) []const u8 {
    assert(row < comp.rows.items.len);
    return comp.pool.stringText(comp.rowAt(row).name);
}

pub fn typeParamCount(comp: *const Compilation, decl_index: Decl.Index) u32 {
    const decl = comp.declAt(decl_index);
    const tree = comp.treeOf(decl.module);
    return switch (tree.viewOf(decl.node)) {
        .struct_decl => |view| @intCast(view.type_params.len),
        .fn_decl => |view| @intCast(view.type_params.len),
        else => 0,
    };
}

/// Textual, which is enough to notice a root file inside the standard library.
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
    return .{ .path = "test.zol", .bytes = buffer[0..text.len :0] };
}

test "instantiation identity is index equality" {
    const gpa = testing.allocator;

    var comp: Compilation = undefined;
    try comp.init(gpa, testing.io, .{ .root_path = "test.zol", .std_dir = null });
    defer comp.deinit();

    try comp.compile(try testSource(gpa,
        \\pub type Box[T] = {
        \\    item: T
        \\}
        \\pub type Boxed = Box[i64]
        \\fn hold(a: Box[i64], b: Boxed, c: Box[u8]) Boxed {
        \\    return a
        \\}
        \\
    ));
    try testing.expectEqual(0, comp.diagnostics.items.len);

    const hold = comp.moduleAt(.root).findDecl(try comp.pool.string(gpa, "hold")).?;
    const instance = try comp.instantiate(hold, &.{});
    const rows = comp.instanceRows(instance);
    try testing.expectEqual(3, rows.len);

    // `Box[i64]` twice, and once through an alias, is one index
    try testing.expectEqual(rows[0].type, rows[1].type);
    try testing.expectEqual(rows[1].type, comp.instanceType(instance));
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
    try comp.init(gpa, testing.io, .{ .root_path = "test.zol", .std_dir = null });
    defer comp.deinit();
    try comp.compile(try testSource(gpa, deep.written()));
    try testing.expectEqual(0, comp.diagnostics.items.len);
}

test "the deepest nesting that reaches analysis does not overflow the stack" {
    const gpa = testing.allocator;

    const levels = analyze_max - 1;
    const nesting = 100;

    var deep: Writer.Allocating = .init(gpa);
    defer deep.deinit();
    for (0..levels) |level| {
        try deep.writer.print("fn g{d}(n: i64) i64 {{ return ", .{level});
        var call_buffer: [16]u8 = undefined;
        const call = try std.fmt.bufPrint(&call_buffer, "g{d}(", .{level + 1});
        try deep.writer.splatBytesAll(call, nesting);
        try deep.writer.writeAll("n");
        try deep.writer.splatBytesAll(")", nesting);
        try deep.writer.writeAll(" }\n");
    }
    try deep.writer.print("fn g{d}(n: i64) i64 {{ return n }}\n", .{levels});

    var comp: Compilation = undefined;
    try comp.init(gpa, testing.io, .{ .root_path = "test.zol", .std_dir = null });
    defer comp.deinit();
    try comp.compile(try testSource(gpa, deep.written()));
    try testing.expectEqual(0, comp.diagnostics.items.len);
}

test "a diagnostic renders across files" {
    const gpa = testing.allocator;

    var comp: Compilation = undefined;
    try comp.init(gpa, testing.io, .{ .root_path = "test.zol", .std_dir = null });
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
