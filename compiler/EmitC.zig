//! The C backend. One translation unit per program, strict C99.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Compilation = @import("Compilation.zig");
const IR = @import("IR.zig");
const Module = @import("Module.zig");
const Pool = @import("Pool.zig");
const spell = @import("util/spell.zig");

comp: *const Compilation,
out: *Writer,
/// Types whose definition is already written, so the walk emits each once.
defined: std.AutoHashMapUnmanaged(Pool.Index, void),

const EmitC = @This();

pub const Error = Writer.Error || Allocator.Error || error{ArenaUnsupported};

/// Emit the whole program. Nothing is written unless every function checked,
/// so the walk below can assume the tables are complete.
pub fn run(comp: *const Compilation, gpa: Allocator, out: *Writer) Error!void {
    assert(comp.diagnostics.items.len == 0);

    var emit: EmitC = .{ .comp = comp, .out = out, .defined = .empty };
    defer emit.defined.deinit(gpa);

    try out.writeAll(
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\
        \\
    );
    try emit.errorEnum();
    try emit.forwardStructs();
    try emit.types(gpa);
    try emit.prototypes();
    for (comp.funcs.items) |*func| try emit.body(func);
    try emit.entryPoint();
}

// types

/// Every error name in the pool, numbered so zero can mean "no error".
fn errorEnum(emit: *EmitC) Error!void {
    const pool = &emit.comp.pool;
    try emit.out.writeAll("typedef uint32_t nul_error;\n");

    var next: u32 = 1;
    for (0..pool.items.len) |raw| {
        const index: Pool.Index = @enumFromInt(@as(u32, @intCast(raw)));
        switch (pool.keyOf(index)) {
            .error_value => |name| {
                try emit.out.print("#define nul_error_{s} ((nul_error){d})\n", .{
                    pool.stringText(name), next,
                });
                next += 1;
            },
            else => {},
        }
    }
    try emit.out.writeByte('\n');
}

/// A tag for every aggregate, so one can be named before it is defined. A
/// struct reaching itself through a pointer needs this.
fn forwardStructs(emit: *EmitC) Error!void {
    const comp = emit.comp;
    for (0..comp.pool.items.len) |raw| {
        const index: Pool.Index = @enumFromInt(@as(u32, @intCast(raw)));
        switch (comp.pool.keyOf(index)) {
            .struct_type, .optional, .error_union => {},
            else => continue,
        }
        try emit.out.writeAll("typedef struct ");
        try emit.typeTag(index);
        try emit.out.writeByte(' ');
        try emit.typeName(index);
        try emit.out.writeAll(";\n");
    }
    try emit.out.writeByte('\n');
}

/// Every aggregate in the pool, each after whatever it embeds by value. A
/// pointer imposes no order, because the tag above already names its pointee.
fn types(emit: *EmitC, gpa: Allocator) Error!void {
    for (0..emit.comp.pool.items.len) |raw| {
        const index: Pool.Index = @enumFromInt(@as(u32, @intCast(raw)));
        switch (emit.comp.pool.keyOf(index)) {
            .struct_type, .optional, .error_union => try emit.define(gpa, index),
            else => {},
        }
    }
    try emit.out.writeByte('\n');
}

/// One type definition, preceded by whatever it embeds by value. A pointer
/// breaks the chain, which is what keeps this walk finite.
fn define(emit: *EmitC, gpa: Allocator, index: Pool.Index) Error!void {
    const comp = emit.comp;
    if (index == .poison) return;
    if (try emit.defined.fetchPut(gpa, index, {}) != null) return;

    switch (comp.pool.keyOf(index)) {
        .simple => {},
        .pointer => {},
        .optional => |child| {
            try emit.define(gpa, child);
            try emit.out.writeAll("struct ");
            try emit.typeTag(index);
            try emit.out.writeAll(" { bool has; ");
            try emit.writeType(child);
            try emit.out.writeAll(" value; };  /* ");
            try spell.writeType(comp, emit.out, index);
            try emit.out.writeAll(" */\n");
        },
        .error_union => |child| {
            try emit.define(gpa, child);
            try emit.out.writeAll("struct ");
            try emit.typeTag(index);
            try emit.out.writeAll(" { nul_error err; ");
            try emit.writeType(child);
            try emit.out.writeAll(" value; };  /* ");
            try spell.writeType(comp, emit.out, index);
            try emit.out.writeAll(" */\n");
        },
        .struct_type => |instance| {
            const rows = comp.instanceRows(instance);
            for (rows) |row| try emit.define(gpa, row.type);

            try emit.out.writeAll("struct ");
            try emit.typeTag(index);
            try emit.out.writeAll(" {\n");
            for (rows) |row| {
                try emit.out.writeAll("    ");
                try emit.writeType(row.type);
                try emit.out.print(" {s};\n", .{comp.pool.stringText(row.name)});
            }
            // an empty struct is not C99, so a placeholder keeps it legal
            if (rows.len == 0) try emit.out.writeAll("    char nul_empty;\n");
            try emit.out.writeAll("};  /* ");
            try spell.writeInstance(comp, emit.out, instance);
            try emit.out.writeAll(" */\n");
        },
        .int, .float, .error_value, .null_typed => unreachable,
    }
}

fn writeType(emit: *EmitC, index: Pool.Index) Error!void {
    const comp = emit.comp;
    switch (comp.pool.keyOf(index)) {
        .simple => |simple| try emit.out.writeAll(switch (simple) {
            .bool => "bool",
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64 => "int64_t",
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .f32 => "float",
            .f64 => "double",
            .nothing => "void",
            .@"error" => "nul_error",
            .poison, .untyped_int, .untyped_float, .true, .false, .null => unreachable,
        }),
        .pointer => |pointer| {
            if (pointer.mutable == false) try emit.out.writeAll("const ");
            try emit.writeType(pointer.child);
            try emit.out.writeByte('*');
        },
        .optional, .error_union, .struct_type => try emit.typeName(index),
        .int, .float, .error_value, .null_typed => unreachable,
    }
}

/// The struct tag behind a typedef, so the two can be written apart.
fn typeTag(emit: *EmitC, index: Pool.Index) Error!void {
    try emit.out.print("nul_tag_{d}", .{index.int()});
}

/// A pool index is one type forever, so it is the whole name a C aggregate
/// needs. The spelled form rides along in a comment at the definition.
fn typeName(emit: *EmitC, index: Pool.Index) Error!void {
    const prefix = switch (emit.comp.pool.keyOf(index)) {
        .optional => "nul_opt",
        .error_union => "nul_err",
        .struct_type => "nul_type",
        else => unreachable,
    };
    try emit.out.print("{s}_{d}", .{ prefix, index.int() });
}

// functions

fn prototypes(emit: *EmitC) Error!void {
    try emit.out.writeByte('\n');
    for (emit.comp.funcs.items) |*func| {
        try emit.signature(func);
        try emit.out.writeAll(";\n");
    }
    try emit.out.writeByte('\n');
}

fn signature(emit: *EmitC, func: *const IR.Func) Error!void {
    const comp = emit.comp;
    try emit.out.writeAll("static ");
    try emit.writeType(comp.instanceType(func.instance));
    try emit.out.writeByte(' ');
    try emit.funcName(func.instance);
    try emit.out.writeByte('(');

    const rows = comp.instanceRows(func.instance);
    if (rows.len == 0) {
        try emit.out.writeAll("void");
    } else {
        for (rows, 0..) |row, position| {
            if (position > 0) try emit.out.writeAll(", ");
            try emit.writeType(row.type);
            // a parameter is the first instructions of the entry block, in order
            try emit.out.print(" t{d}", .{position});
        }
    }
    try emit.out.writeByte(')');
}

/// The instantiation index makes the name injective across modules and
/// arguments alike.
fn funcName(emit: *EmitC, instance: Pool.Instance) Error!void {
    const decl = emit.comp.declAt(emit.comp.instanceDecl(instance));
    try emit.out.print("nul_{s}_{d}", .{
        emit.comp.pool.stringText(decl.name), instance.int(),
    });
}

fn body(emit: *EmitC, func: *const IR.Func) Error!void {
    const comp = emit.comp;
    try emit.out.writeAll("/* ");
    try spell.writeInstance(comp, emit.out, func.instance);
    try emit.out.writeAll(" */\n");
    try emit.signature(func);
    try emit.out.writeAll(" {\n");

    try emit.temporaries(func);
    for (func.blocks, 0..) |block, index| {
        // a label nothing jumps to is a warning, and the entry falls through
        if (isTarget(func, @intCast(index))) try emit.out.print("b{d}:;\n", .{index});
        for (block.first..block.first + block.count) |raw| {
            try emit.inst(func, @intCast(raw));
        }
        try emit.terminator(block.terminator);
    }
    try emit.out.writeAll("}\n\n");
}

/// Whether any terminator names this block, so an unreachable label is never
/// written.
fn isTarget(func: *const IR.Func, index: u32) bool {
    for (func.blocks) |block| {
        switch (block.terminator) {
            .none => unreachable,
            .jump => |target| if (target.int() == index) return true,
            .branch => |branch| {
                if (branch.then_block.int() == index) return true;
                if (branch.else_block.int() == index) return true;
            },
            .ret => {},
        }
    }
    return false;
}

/// One local per instruction a live block defines. Dropped blocks leave gaps
/// in the numbering, and a temporary for one would never be assigned.
fn temporaries(emit: *EmitC, func: *const IR.Func) Error!void {
    const params: u32 = @intCast(emit.comp.instanceRows(func.instance).len);
    for (func.blocks) |block| {
        for (block.first..block.first + block.count) |raw| {
            const index: u32 = @intCast(raw);
            if (index < params) continue;
            const produced = func.insts.items(.type)[index];
            if (produced == .nothing_type) continue;
            if (produced == .poison) continue;

            try emit.out.writeAll("    ");
            try emit.writeType(produced);
            try emit.out.print(" t{d};\n", .{index});
        }
    }
}

fn inst(emit: *EmitC, func: *const IR.Func, index: u32) Error!void {
    const comp = emit.comp;
    const tag = func.insts.items(.tag)[index];
    const data = func.insts.items(.data)[index];
    const produced = func.insts.items(.type)[index];

    switch (tag) {
        // the parameter is already the C parameter, and a scope is the
        // arena checker's business rather than the backend's
        .param, .scope_begin, .scope_end => return,

        .local => {
            const slot = comp.pool.keyOf(produced).pointer.child;
            try emit.out.writeAll("    ");
            try emit.writeType(slot);
            try emit.out.print(" t{d}_slot; t{d} = &t{d}_slot;\n", .{ index, index, index });
        },
        .load => {
            try emit.out.print("    t{d} = *", .{index});
            try emit.ref(data.un);
            try emit.out.writeAll(";\n");
        },
        .store => {
            try emit.out.writeAll("    *");
            try emit.ref(data.bin.lhs);
            try emit.out.writeAll(" = ");
            try emit.ref(data.bin.rhs);
            try emit.out.writeAll(";\n");
        },
        .field_ptr => {
            try emit.out.print("    t{d} = &(", .{index});
            try emit.ref(data.field.base);
            try emit.out.print("->{s});\n", .{comp.rowName(data.field.row)});
        },
        .field_val => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.ref(data.field.base);
            try emit.out.print(").{s};\n", .{comp.rowName(data.field.row)});
        },

        .add, .sub, .mul => try emit.arithmetic(index, tag, produced, data),
        .div, .mod => {
            try emit.out.print("    t{d} = ", .{index});
            try emit.ref(data.bin.lhs);
            try emit.out.writeAll(if (tag == .div) " / " else " % ");
            try emit.ref(data.bin.rhs);
            try emit.out.writeAll(";\n");
        },
        .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => {
            try emit.out.print("    t{d} = ", .{index});
            try emit.ref(data.bin.lhs);
            try emit.out.writeAll(switch (tag) {
                .cmp_eq => " == ",
                .cmp_ne => " != ",
                .cmp_lt => " < ",
                .cmp_le => " <= ",
                .cmp_gt => " > ",
                .cmp_ge => " >= ",
                else => unreachable,
            });
            try emit.ref(data.bin.rhs);
            try emit.out.writeAll(";\n");
        },
        .negate => {
            try emit.out.print("    t{d} = -", .{index});
            try emit.ref(data.un);
            try emit.out.writeAll(";\n");
        },
        .not => {
            try emit.out.print("    t{d} = !", .{index});
            try emit.ref(data.un);
            try emit.out.writeAll(";\n");
        },

        .call => {
            const call = func.callAt(data.payload);
            try emit.out.writeAll("    ");
            if (produced != .nothing_type) try emit.out.print("t{d} = ", .{index});
            switch (call.callee.unwrap()) {
                .instance => |callee| {
                    try emit.funcName(callee);
                    try emit.out.writeByte('(');
                },
            }
            for (call.args, 0..) |argument, position| {
                if (position > 0) try emit.out.writeAll(", ");
                try emit.ref(argument);
            }
            try emit.out.writeAll(");\n");
        },
        .struct_init => {
            const fields = func.structInitAt(data.payload);
            const instance = comp.pool.keyOf(produced).struct_type;
            const rows = comp.instanceRows(instance);
            try emit.out.print("    t{d} = (", .{index});
            try emit.typeName(produced);
            try emit.out.writeAll("){ ");
            for (fields, 0..) |field, position| {
                if (position > 0) try emit.out.writeAll(", ");
                try emit.out.print(".{s} = ", .{comp.pool.stringText(rows[position].name)});
                try emit.ref(field);
            }
            try emit.out.writeAll(" };\n");
        },

        .wrap_optional => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.typeName(produced);
            try emit.out.writeAll("){ .has = true, .value = ");
            try emit.ref(data.un);
            try emit.out.writeAll(" };\n");
        },
        .has_value => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.ref(data.un);
            try emit.out.writeAll(").has;\n");
        },
        .unwrap_value, .unwrap_ok => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.ref(data.un);
            try emit.out.writeAll(").value;\n");
        },
        .wrap_ok => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.typeName(produced);
            try emit.out.writeAll("){ .err = 0, .value = ");
            try emit.ref(data.un);
            try emit.out.writeAll(" };\n");
        },
        .wrap_err => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.typeName(produced);
            try emit.out.writeAll("){ .err = ");
            try emit.ref(data.un);
            try emit.out.writeAll(" };\n");
        },
        .is_error => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.ref(data.un);
            try emit.out.writeAll(").err != 0;\n");
        },
        .unwrap_err => {
            try emit.out.print("    t{d} = (", .{index});
            try emit.ref(data.un);
            try emit.out.writeAll(").err;\n");
        },

        // the backend has no arena runtime yet, so a program that allocates
        // is refused rather than half emitted
        .arena_init,
        .arena_child,
        .arena_create,
        .arena_copy,
        .arena_reset,
        .arena_destroy,
        => return error.ArenaUnsupported,
    }
}

/// Wrapping is spelled through unsigned arithmetic, so the result is defined
/// under any conforming compiler rather than under one flag of one of them.
fn arithmetic(
    emit: *EmitC,
    index: u32,
    tag: IR.Inst.Tag,
    produced: Pool.Index,
    data: IR.Inst.Data,
) Error!void {
    const operator = switch (tag) {
        .add => " + ",
        .sub => " - ",
        .mul => " * ",
        else => unreachable,
    };
    const wrapping = unsignedOf(produced);
    try emit.out.print("    t{d} = ", .{index});
    if (wrapping) |unsigned| {
        try emit.out.writeAll("(");
        try emit.writeType(produced);
        try emit.out.print(")(({s})", .{unsigned});
        try emit.ref(data.bin.lhs);
        try emit.out.print("{s}({s})", .{ operator, unsigned });
        try emit.ref(data.bin.rhs);
        try emit.out.writeAll(")");
    } else {
        try emit.ref(data.bin.lhs);
        try emit.out.writeAll(operator);
        try emit.ref(data.bin.rhs);
    }
    try emit.out.writeAll(";\n");
}

/// The unsigned type of the same width, or null for a float, which already
/// wraps to infinity rather than overflowing.
fn unsignedOf(index: Pool.Index) ?[]const u8 {
    return switch (index) {
        .i8_type, .u8_type => "uint8_t",
        .i16_type, .u16_type => "uint16_t",
        .i32_type, .u32_type => "uint32_t",
        .i64_type, .u64_type => "uint64_t",
        else => null,
    };
}

fn terminator(emit: *EmitC, term: IR.Terminator) Error!void {
    switch (term) {
        .none => unreachable,
        .jump => |target| try emit.out.print("    goto b{d};\n", .{target.int()}),
        .branch => |branch| {
            try emit.out.writeAll("    if (");
            try emit.ref(branch.cond);
            try emit.out.print(") goto b{d}; else goto b{d};\n", .{
                branch.then_block.int(), branch.else_block.int(),
            });
        },
        .ret => |value| {
            if (value == .none) {
                try emit.out.writeAll("    return;\n");
            } else {
                try emit.out.writeAll("    return ");
                try emit.ref(value);
                try emit.out.writeAll(";\n");
            }
        },
    }
}

// operands

fn ref(emit: *EmitC, operand: IR.Ref) Error!void {
    assert(operand != .none);
    switch (operand.unwrap()) {
        .inst => |index| try emit.out.print("t{d}", .{index.int()}),
        .constant => |value| try emit.constant(value),
    }
}

fn constant(emit: *EmitC, value: Pool.Index) Error!void {
    const comp = emit.comp;
    switch (comp.pool.keyOf(value)) {
        .simple => |simple| try emit.out.writeAll(switch (simple) {
            .true => "true",
            .false => "false",
            else => unreachable,
        }),
        .int => |it| {
            const suffix: []const u8 = if (it.value < 0) "LL" else "ULL";
            try emit.out.writeAll("(");
            try emit.writeType(if (it.type == .untyped_int_type) .i64_type else it.type);
            try emit.out.print("){d}{s}", .{ it.value, suffix });
        },
        .float => |it| try emit.out.print("{d}", .{it.value}),
        .error_value => |name| {
            try emit.out.print("nul_error_{s}", .{comp.pool.stringText(name)});
        },
        .null_typed => |carried| {
            try emit.out.writeByte('(');
            try emit.typeName(carried);
            try emit.out.writeAll("){ .has = false }");
        },
        .pointer, .optional, .error_union, .struct_type => unreachable,
    }
}

// the entry point

/// `main` in the root module is where a program starts. C wants an `int`, so
/// the result is narrowed the way an exit status already is.
fn entryPoint(emit: *EmitC) Error!void {
    const comp = emit.comp;
    const root = comp.moduleAt(.root);
    for (comp.funcs.items) |*func| {
        const decl_index = comp.instanceDecl(func.instance);
        const decl = comp.declAt(decl_index);
        if (decl.module != .root) continue;
        if (decl.owner != .none) continue;
        if (std.mem.eql(u8, comp.pool.stringText(decl.name), "main") == false) continue;

        try emit.out.writeAll("int main(void) { return (int)");
        try emit.funcName(func.instance);
        try emit.out.writeAll("(); }\n");
        return;
    }
    _ = root;
}
