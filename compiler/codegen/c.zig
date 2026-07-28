//! Emits C from `Nir`. One C local per instruction, since an instruction's index
//! already names its value and nothing is assigned twice, except a slot, which is
//! exactly the thing the source mutates.
//!
//! Control flow is labels and gotos, one label per block anything jumps to, and every
//! declaration is hoisted, since a C local declared inside a branch is not visible
//! after it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ast = @import("../Ast.zig");
const Namespace = @import("../Namespace.zig");
const Nir = @import("../Nir.zig");
const Type = @import("../Type.zig");

const Ref = Nir.Ref;

pub const Error = Allocator.Error || Io.Writer.Error;

pub fn emit(
    gpa: Allocator,
    types: *const Type,
    tree: *const Ast,
    namespace: *Namespace,
    functions: []const Nir.Function,
    w: *Io.Writer,
) Error!void {
    const e: Emit = .{ .gpa = gpa, .types = types, .tree = tree, .namespace = namespace, .w = w };
    try e.run(functions);
}

const Emit = struct {
    gpa: Allocator,
    types: *const Type,
    tree: *const Ast,
    namespace: *Namespace,
    w: *Io.Writer,

    fn run(e: Emit, functions: []const Nir.Function) Error!void {
        const w = e.w;
        try w.writeAll(prelude);
        try e.structs();
        try w.writeByte('\n');
        for (functions) |b| {
            try e.signature(b);
            try w.writeAll(";\n");
        }
        for (functions) |b| {
            try w.writeByte('\n');
            try e.function(b);
        }
        try e.entry(functions);
    }

    // Declarations

    /// Every struct is forward declared before any is defined, so two can point at each other.
    fn structs(e: Emit) Io.Writer.Error!void {
        for (e.namespace.all()) |decl| {
            const ty = e.structOf(decl) orelse continue;
            const name = e.types.stringBytes(e.types.structName(ty));
            try e.w.print("typedef struct {s} {s};\n", .{ name, name });
        }
        for (e.namespace.all()) |decl| {
            const ty = e.structOf(decl) orelse continue;
            if (!e.types.isDefined(ty)) continue;

            try e.w.print("\nstruct {s} {{\n", .{e.types.stringBytes(e.types.structName(ty))});
            const names = e.types.fieldNames(ty);
            for (names, e.types.fieldTypes(ty)) |field, field_ty| {
                try e.w.writeAll("    ");
                try e.writeType(field_ty);
                try e.w.print(" {s};\n", .{e.types.stringBytes(field)});
            }
            try e.w.writeAll("};\n");
        }
    }

    fn structOf(e: Emit, decl: Namespace.Decl) ?Type.Index {
        const ty = decl.value.asType() orelse return null;
        return if (e.types.isStruct(ty)) ty else null;
    }

    fn signature(e: Emit, b: Nir.Function) Io.Writer.Error!void {
        const func = e.types.funcOf(b.decl.value.ty) orelse return;

        try e.writeType(func.return_type);
        try e.w.print(" {s}(", .{symbol(e.tree.tokenSlice(b.decl.name_token))});
        if (func.params.len == 0) try e.w.writeAll("void");
        for (func.params, 0..) |param, at| {
            if (at > 0) try e.w.writeAll(", ");
            try e.writeType(param);
            try e.w.print(" t{d}", .{at});
        }
        try e.w.writeByte(')');
    }

    fn function(e: Emit, b: Nir.Function) Error!void {
        const nir = b.body;
        const reach = try Nir.reachableBlocks(e.gpa, nir.blocks);
        defer e.gpa.free(reach);
        const labeled = try e.labelTargets(nir, reach);
        defer e.gpa.free(labeled);
        const places = try e.storePlaces(nir);
        defer e.gpa.free(places);

        try e.signature(b);
        try e.w.writeAll(" {\n");

        // Hoisted, so a value born in one branch is still nameable after the join.
        for (nir.blocks, 0..) |blk, at| {
            if (!reach[at]) continue;
            for (blk.first..blk.end()) |i| {
                const inst = nir.insts[i];
                if (!needsLocal(inst, places[i])) continue;
                try e.w.writeAll("    ");
                try e.writeType(inst.val.ty);
                try e.w.print(" t{d};\n", .{i});
            }
        }

        for (nir.blocks, 0..) |blk, at| {
            if (!reach[at]) continue;
            if (labeled[at]) try e.w.print("b{d}:;\n", .{at});
            for (blk.first..blk.end()) |i| {
                try e.instruction(nir, @intCast(i), nir.insts[i], places[i]);
            }
            try e.terminator(nir, blk.term, nextEmitted(reach, at));
        }
        try e.w.writeAll("}\n");
    }

    /// Fields only ever written through. Loading one would be a dead read of the memory
    /// about to be overwritten.
    fn storePlaces(e: Emit, nir: Nir) Allocator.Error![]bool {
        const places = try e.gpa.alloc(bool, nir.insts.len);
        @memset(places, false);
        for (nir.insts) |inst| switch (inst.data) {
            .store_field => |it| places[it.place.i()] = true,
            else => {},
        };
        return places;
    }

    /// Blocks some emitted goto targets. A jump onto the next block is a fallthrough.
    fn labelTargets(e: Emit, nir: Nir, reach: []const bool) Allocator.Error![]bool {
        const labeled = try e.gpa.alloc(bool, nir.blocks.len);
        @memset(labeled, false);
        for (nir.blocks, 0..) |blk, at| {
            if (!reach[at]) continue;
            const next = nextEmitted(reach, at);
            switch (blk.term) {
                .jump => |t| if (@intFromEnum(t) != next) {
                    labeled[@intFromEnum(t)] = true;
                },
                .branch => |it| {
                    const then = @intFromEnum(it.then);
                    const els = @intFromEnum(it.els);
                    if (then == next) {
                        labeled[els] = true;
                    } else {
                        labeled[then] = true;
                        if (els != next) labeled[els] = true;
                    }
                },
                .ret => {},
            }
        }
        return labeled;
    }

    fn nextEmitted(reach: []const bool, at: usize) usize {
        var next = at + 1;
        while (next < reach.len and !reach[next]) next += 1;
        return next;
    }

    fn terminator(e: Emit, nir: Nir, term: Nir.Term, next: usize) Io.Writer.Error!void {
        switch (term) {
            .jump => |t| {
                if (@intFromEnum(t) == next) return; // fallthrough
                try e.w.print("    goto b{d};\n", .{@intFromEnum(t)});
            },
            .branch => |it| {
                const then = @intFromEnum(it.then);
                const els = @intFromEnum(it.els);
                if (then == next) {
                    try e.w.writeAll("    if (!");
                    try e.ref(nir, it.cond);
                    try e.w.print(") goto b{d};\n", .{els});
                } else {
                    try e.w.writeAll("    if (");
                    try e.ref(nir, it.cond);
                    try e.w.print(") goto b{d};\n", .{then});
                    if (els != next) try e.w.print("    goto b{d};\n", .{els});
                }
            },
            .ret => |r| {
                const value = r.value orelse return e.w.writeAll("    return;\n");
                try e.w.writeAll("    return ");
                try e.ref(nir, value);
                try e.w.writeAll(";\n");
            },
        }
    }

    /// Whether an instruction owns a hoisted C local. Parameters are named by the
    /// signature, and a declaration is spelled where it is used.
    fn needsLocal(inst: Nir.Inst, is_place: bool) bool {
        if (inst.val.ty == .void or inst.val.isKnown()) return false;
        return switch (inst.data) {
            .arg, .decl, .constant => false,
            .field => !is_place,
            else => true,
        };
    }

    /// A `main` in the source becomes the C entry point, with a root arena around it.
    fn entry(e: Emit, functions: []const Nir.Function) Io.Writer.Error!void {
        for (functions) |b| {
            if (!std.mem.eql(u8, e.tree.tokenSlice(b.decl.name_token), "main")) continue;
            const func = e.types.funcOf(b.decl.value.ty) orelse return;
            const takes_arena = func.params.len == 1 and func.params[0] == .Arena;
            const returns = func.return_type != .void;

            try e.w.writeAll("\nint main(void) {\n");
            if (takes_arena) try e.w.writeAll("    nul_arena *root = nul_arena_init();\n");
            try e.w.writeAll("    ");
            if (returns) try e.w.writeAll("int64_t code = ");
            try e.w.print("nul_main({s});\n", .{if (takes_arena) "root" else ""});
            if (takes_arena) try e.w.writeAll("    nul_arena_destroy(root);\n");
            try e.w.print("    return {s};\n}}\n", .{if (returns) "(int)code" else "0"});
            return;
        }
    }

    // Instructions

    fn instruction(e: Emit, nir: Nir, at: u32, inst: Nir.Inst, is_place: bool) Io.Writer.Error!void {
        // A known value never materializes, since `ref` spells it at each use.
        if (inst.val.isKnown()) return;
        switch (inst.data) {
            // A slot is its hoisted declaration, and nothing more.
            .arg, .decl, .constant, .alloc => return,
            .store => |it| {
                try e.w.print("    t{d} = ", .{it.slot.i()});
                try e.ref(nir, it.value);
                return e.w.writeAll(";\n");
            },
            // The one instruction naming a place rather than making a value.
            .store_field => |it| {
                try e.w.writeAll("    ");
                try e.place(nir, it.place, .store);
                try e.w.writeAll(" = ");
                try e.ref(nir, it.value);
                return e.w.writeAll(";\n");
            },
            // No value, so nothing to bind.
            .arena_reset => |arena| return e.w.print("    nul_arena_reset(t{d});\n", .{arena.i()}),
            // Nulled after, so an explicit `destroy` and the scope's end never free twice.
            .arena_destroy, .arena_end => |arena| {
                return e.w.print("    nul_arena_destroy(t{d}); t{d} = NULL;\n", .{ arena.i(), arena.i() });
            },
            .field => if (is_place) return,
            else => {},
        }

        try e.w.writeAll("    ");
        // A call for its effect has no value to bind, and C has no `void` variables.
        if (inst.val.ty != .void) try e.w.print("t{d} = ", .{at});
        try e.expression(nir, at, inst);
        try e.w.writeAll(";\n");
    }

    fn expression(e: Emit, nir: Nir, at: u32, inst: Nir.Inst) Io.Writer.Error!void {
        const text = e.tree.tokenSlice(inst.token);
        switch (inst.data) {
            // The token still has its quotes, and the length is what is inside them.
            .str => try e.w.print("(nul_str){{ {s}, {d} }}", .{ text, text.len - 2 }),
            .binary => |it| {
                try e.ref(nir, it.lhs);
                try e.w.print(" {s} ", .{text});
                try e.ref(nir, it.rhs);
            },
            .unary => |operand| {
                try e.w.writeAll(text);
                try e.ref(nir, operand);
            },
            .coerce => |operand| try e.ref(nir, operand),
            .load => |slot| try e.w.print("t{d}", .{slot.i()}),
            .field => try e.place(nir, @enumFromInt(at), .read),
            .call => |call| {
                try e.w.print("{s}(", .{symbol(e.tree.tokenSlice(nir.get(call.callee).token))});
                for (nir.refs(call.args), 0..) |arg, position| {
                    if (position > 0) try e.w.writeAll(", ");
                    try e.ref(nir, arg);
                }
                try e.w.writeByte(')');
            },
            .arena_init => try e.w.writeAll("nul_arena_init()"),
            .arena_child => |parent| try e.w.print("nul_arena_child(t{d})", .{parent.i()}),
            .arena_create => |arena| {
                try e.w.print("nul_arena_alloc(t{d}, sizeof(", .{arena.i()});
                try e.writeType(e.types.pointeeOf(inst.val.ty) orelse inst.val.ty);
                try e.w.writeAll("))");
            },
            // Only `str` owns bytes worth duplicating, and anything flat is already a copy.
            .arena_copy => |it| if (inst.val.ty == .str) {
                try e.w.print("nul_arena_copy_str(t{d}, t{d})", .{ it.arena.i(), it.value.i() });
            } else {
                try e.ref(nir, it.value);
            },
            .todo => try e.w.writeAll("0 /* not lowered */"),
            // Handled in `instruction`, or never a value at all.
            .arg, .decl, .constant, .alloc, .store => unreachable,
            .store_field, .arena_reset, .arena_destroy, .arena_end => unreachable,
        }
    }

    /// How an operand is spelled, its value when the compiler knows it and its local
    /// when only the program does.
    fn ref(e: Emit, nir: Nir, r: Ref) Io.Writer.Error!void {
        switch (nir.get(r).val.known) {
            .runtime => try e.w.print("t{d}", .{r.i()}),
            .int => |x| try e.w.print("{d}", .{x}),
            .float => |x| try e.w.print("{d}", .{x}),
            .bool => |x| try e.w.writeAll(if (x) "true" else "false"),
            .type => try e.w.writeAll("0"), // a type has no runtime spelling
        }
    }

    const Access = enum { read, store };

    /// `t3->next`, the lvalue a `field` instruction denotes. Writing a field of a
    /// value held in a slot goes through the slot itself, since a loaded copy would
    /// take the write and throw it away.
    fn place(e: Emit, nir: Nir, at: Ref, access: Access) Io.Writer.Error!void {
        const it = switch (nir.get(at).data) {
            .field => |f| f,
            else => unreachable,
        };
        const base_ty = nir.get(it.base).val.ty;
        const owner = e.types.pointeeOf(base_ty) orelse base_ty;
        const name = e.types.fieldNames(owner)[it.index];
        const through_pointer = e.types.pointeeOf(base_ty) != null;

        var base = it.base;
        if (access == .store and !through_pointer) switch (nir.get(it.base).data) {
            .load => |slot| base = slot,
            else => {},
        };
        try e.w.print("t{d}{s}{s}", .{
            base.i(),
            if (through_pointer) "->" else ".",
            e.types.stringBytes(name),
        });
    }

    fn symbol(name: []const u8) []const u8 {
        return if (std.mem.eql(u8, name, "main")) "nul_main" else name;
    }

    // Types

    fn writeType(e: Emit, ty: Type.Index) Io.Writer.Error!void {
        if (e.types.pointeeOf(ty)) |pointee| {
            try e.writeType(pointee);
            return e.w.writeAll(" *");
        }
        if (e.types.isStruct(ty)) {
            return e.w.writeAll(e.types.stringBytes(e.types.structName(ty)));
        }
        try e.w.writeAll(switch (ty) {
            .void, .never => "void",
            .bool => "bool",
            .str => "nul_str",
            .Arena => "nul_arena *",
            .f32 => "float",
            .f64, .comptime_float => "double",
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64, .comptime_int => "int64_t",
            .isize => "intptr_t",
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .usize => "uintptr_t",
            else => "void *",
        });
    }

    const prelude =
        \\// Generated by nul. Do not edit.
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\#include <string.h>
        \\
        \\typedef struct { const char *ptr; int64_t len; } nul_str;
        \\
        \\// A bump allocator, and the only thing the language needs at run time. A child
        \\// borrows its parent's block, so releasing a parent releases every child with it.
        \\typedef struct nul_arena nul_arena;
        \\struct nul_arena {
        \\    unsigned char *base;
        \\    size_t size;
        \\    size_t used;
        \\    nul_arena *parent;
        \\};
        \\
        \\#define NUL_ARENA_SIZE (1u << 22)
        \\
        \\nul_arena *nul_arena_init(void) {
        \\    nul_arena *a = (nul_arena *)calloc(1, sizeof(nul_arena));
        \\    a->base = (unsigned char *)malloc(NUL_ARENA_SIZE);
        \\    a->size = NUL_ARENA_SIZE;
        \\    return a;
        \\}
        \\
        \\nul_arena *nul_arena_child(nul_arena *parent) {
        \\    nul_arena *a = nul_arena_init();
        \\    a->parent = parent;
        \\    return a;
        \\}
        \\
        \\void *nul_arena_alloc(nul_arena *a, size_t size) {
        \\    size_t aligned = (a->used + 15u) & ~(size_t)15u;
        \\    if (aligned + size > a->size) abort();
        \\    a->used = aligned + size;
        \\    return a->base + aligned;
        \\}
        \\
        \\void nul_arena_reset(nul_arena *a) { a->used = 0; }
        \\
        \\// NULL tolerant, so an early 'destroy' and the scope's own cleanup never
        \\// free twice.
        \\void nul_arena_destroy(nul_arena *a) {
        \\    if (!a) return;
        \\    free(a->base);
        \\    free(a);
        \\}
        \\
        \\nul_str nul_arena_copy_str(nul_arena *a, nul_str s) {
        \\    char *bytes = (char *)nul_arena_alloc(a, (size_t)s.len + 1);
        \\    memcpy(bytes, s.ptr, (size_t)s.len);
        \\    bytes[s.len] = 0;
        \\    return (nul_str){ bytes, s.len };
        \\}
        \\
        \\
    ;
};
