//! Emits C from `Nir`. One C local per instruction, since an instruction's index already
//! names its value and nothing is ever assigned twice.

const std = @import("std");
const Io = std.Io;

const Ast = @import("../Ast.zig");
const Namespace = @import("../Namespace.zig");
const Nir = @import("../Nir.zig");
const Type = @import("../Type.zig");

pub fn emit(
    types: *const Type,
    tree: *const Ast,
    namespace: *Namespace,
    functions: []const Nir.Function,
    w: *Io.Writer,
) Io.Writer.Error!void {
    const e: Emit = .{ .types = types, .tree = tree, .namespace = namespace, .w = w };
    try e.run(functions);
}

const Emit = struct {
    types: *const Type,
    tree: *const Ast,
    namespace: *Namespace,
    w: *Io.Writer,

    fn run(e: Emit, functions: []const Nir.Function) Io.Writer.Error!void {
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

    /// Every struct is forward declared before any is defined, which is what lets two of them
    /// point at each other.
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

    fn function(e: Emit, b: Nir.Function) Io.Writer.Error!void {
        try e.signature(b);
        try e.w.writeAll(" {\n");
        for (b.body.insts, 0..) |inst, at| {
            if (isPlace(b.body, @intCast(at))) continue;
            try e.instruction(b.body, @intCast(at), inst);
        }
        try e.w.writeAll("}\n");
    }

    /// Whether a `field` is only ever written through, in which case loading it would be a
    /// dead read of the very memory about to be overwritten.
    fn isPlace(nir: Nir, at: u32) bool {
        if (nir.insts[at].tag != .field) return false;
        for (nir.insts) |inst| {
            if (inst.tag == .store_field and inst.lhs == at) return true;
        }
        return false;
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

    fn instruction(e: Emit, nir: Nir, at: u32, inst: Nir.Inst) Io.Writer.Error!void {
        // A known value never materializes, since `ref` spells it at each use.
        if (inst.val.isKnown()) return;
        switch (inst.tag) {
            // Parameters are named by the signature, and a declaration is spelled where it is
            // used. Neither needs a local of its own.
            .arg, .decl, .constant => return,
            .ret => {
                const value = Nir.retOperand(inst) orelse return e.w.writeAll("    return;\n");
                try e.w.writeAll("    return ");
                try e.ref(nir, value);
                return e.w.writeAll(";\n");
            },
            // A store is the one instruction that names a place rather than making a value.
            .store_field => {
                try e.w.writeAll("    ");
                try e.place(nir, inst.lhs);
                try e.w.writeAll(" = ");
                try e.ref(nir, inst.rhs);
                return e.w.writeAll(";\n");
            },
            // No value, so nothing to bind.
            .arena_reset => return e.w.print("    nul_arena_reset(t{d});\n", .{inst.lhs}),
            .arena_destroy, .arena_end => {
                return e.w.print("    nul_arena_destroy(t{d});\n", .{inst.lhs});
            },
            else => {},
        }

        try e.w.writeAll("    ");
        // A call for its effect has no value to bind, and C has no `void` variables.
        if (inst.val.ty != .void) {
            try e.writeType(inst.val.ty);
            try e.w.print(" t{d} = ", .{at});
        }
        try e.expression(nir, at, inst);
        try e.w.writeAll(";\n");
    }

    fn expression(e: Emit, nir: Nir, at: u32, inst: Nir.Inst) Io.Writer.Error!void {
        const text = e.tree.tokenSlice(inst.token);
        switch (inst.tag) {
            // The token still has its quotes, and the length is what is inside them.
            .str => try e.w.print("(nul_str){{ {s}, {d} }}", .{ text, text.len - 2 }),
            .binary => {
                try e.ref(nir, inst.lhs);
                try e.w.print(" {s} ", .{cOperator(text)});
                try e.ref(nir, inst.rhs);
            },
            .unary => {
                try e.w.writeAll(cOperator(text));
                try e.ref(nir, inst.lhs);
            },
            .coerce => try e.ref(nir, inst.lhs),
            .field => try e.place(nir, at),
            .call => {
                try e.w.print("{s}(", .{symbol(e.tree.tokenSlice(nir.insts[inst.lhs].token))});
                for (nir.callArgs(inst), 0..) |arg, i| {
                    if (i > 0) try e.w.writeAll(", ");
                    try e.ref(nir, arg);
                }
                try e.w.writeByte(')');
            },
            .arena_init => try e.w.writeAll("nul_arena_init()"),
            .arena_child => try e.w.print("nul_arena_child(t{d})", .{inst.lhs}),
            .arena_create => {
                try e.w.print("nul_arena_alloc(t{d}, sizeof(", .{inst.lhs});
                try e.writeType(e.types.pointeeOf(inst.val.ty) orelse inst.val.ty);
                try e.w.writeAll("))");
            },
            // Only `str` owns bytes worth duplicating, and anything flat is already a copy.
            .arena_copy => if (inst.val.ty == .str) {
                try e.w.print("nul_arena_copy_str(t{d}, t{d})", .{ inst.lhs, inst.rhs });
            } else {
                try e.ref(nir, inst.rhs);
            },
            .arg, .decl, .constant => unreachable, // never bound to a local
            .ret, .store_field, .arena_reset, .arena_destroy, .arena_end => unreachable,
            .todo => try e.w.writeAll("0 /* not lowered */"),
        }
    }

    /// How an operand is spelled, its value when the compiler knows it and its local
    /// when only the program does.
    fn ref(e: Emit, nir: Nir, at: u32) Io.Writer.Error!void {
        switch (nir.insts[at].val.known) {
            .runtime => try e.w.print("t{d}", .{at}),
            .int => |x| try e.w.print("{d}", .{x}),
            .float => |x| try e.w.print("{d}", .{x}),
            .bool => |x| try e.w.writeAll(if (x) "true" else "false"),
            .type => try e.w.writeAll("0"), // a type has no runtime spelling
        }
    }

    /// `t3->next`, the lvalue a `field` instruction denotes.
    fn place(e: Emit, nir: Nir, at: u32) Io.Writer.Error!void {
        const inst = nir.insts[at];
        const base = nir.insts[inst.lhs].val.ty;
        const owner = e.types.pointeeOf(base) orelse base;
        const name = e.types.fieldNames(owner)[inst.rhs];
        const arrow = if (e.types.pointeeOf(base) == null) "." else "->";
        try e.w.print("t{d}{s}{s}", .{ inst.lhs, arrow, e.types.stringBytes(name) });
    }

    /// C owns `main`, so the source's own is spelled out of the way.
    fn symbol(name: []const u8) []const u8 {
        return if (std.mem.eql(u8, name, "main")) "nul_main" else name;
    }

    fn cOperator(text: []const u8) []const u8 {
        if (std.mem.eql(u8, text, "and")) return "&&";
        if (std.mem.eql(u8, text, "or")) return "||";
        return text;
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
        \\void nul_arena_destroy(nul_arena *a) { free(a->base); free(a); }
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
