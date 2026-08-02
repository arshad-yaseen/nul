const std = @import("std");
const assert = std.debug.assert;

const compiler = @import("compiler");

const Compilation = compiler.Compilation;
const IR = compiler.IR;
const Pool = compiler.Pool;

pub fn all(comp: *const Compilation) void {
    // a poison type can survive a body that reported, and none may survive one
    // that did not
    const clean = comp.diagnostics.items.len == 0;
    for (comp.funcs.items) |*func| func_(comp, func, clean);
}

fn func_(comp: *const Compilation, func: *const IR.Func, clean: bool) void {
    assert(func.blocks.len > 0);

    for (func.blocks) |block| {
        // `finish` drops what nothing reaches, so what survives has to end
        assert(block.terminator != .none);
        assert(block.end() <= func.insts.len);
        terminator(func, block.terminator);
    }

    var walk = func.instructions();
    while (walk.next()) |index| inst(comp, func, index, clean);
}

fn terminator(func: *const IR.Func, term: IR.Terminator) void {
    switch (term) {
        .none => unreachable,
        .jump => |target| assert(target.int() < func.blocks.len),
        .branch => |branch| {
            assert(branch.then_block.int() < func.blocks.len);
            assert(branch.else_block.int() < func.blocks.len);
            operand(func, branch.cond);
        },
        .ret => |value| if (value != .none) operand(func, value),
    }
}

fn inst(comp: *const Compilation, func: *const IR.Func, index: IR.Inst.Index, clean: bool) void {
    const at = index.int();
    assert(at < func.insts.len);

    const tag = func.insts.items(.tag)[at];
    const data = func.insts.items(.data)[at];
    const produced = func.insts.items(.type)[at];

    // `*var poison` passes `isType` and breaks the backend, so this looks all
    // the way down
    if (produced != .nothing_type) {
        if (clean) assert(sound(comp, produced, 0));
    }

    switch (tag) {
        .param, .local, .arena_init, .scope_begin => {},

        .scope_end => {
            // or the nesting is a fiction
            operand(func, data.un);
            switch (data.un.unwrap()) {
                .inst => |marker| assert(func.insts.items(.tag)[marker.int()] == .scope_begin),
                .constant => unreachable,
            }
        },

        .load,
        .negate,
        .not,
        .arena_child,
        .arena_create,
        .arena_reset,
        .arena_destroy,
        .wrap_optional,
        .has_value,
        .unwrap_value,
        .wrap_ok,
        .wrap_err,
        .is_error,
        .unwrap_ok,
        .unwrap_err,
        => operand(func, data.un),

        .store,
        .arena_copy,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .cmp_eq,
        .cmp_ne,
        .cmp_lt,
        .cmp_le,
        .cmp_gt,
        .cmp_ge,
        => {
            operand(func, data.bin.lhs);
            operand(func, data.bin.rhs);
        },

        .field_ptr, .field_val => {
            operand(func, data.field.base);
            assert(data.field.row < comp.rows.items.len);
        },

        .call => {
            const call = func.callAt(data.payload);
            for (call.args) |argument| operand(func, argument);
        },

        .struct_init => {
            for (func.structInitAt(data.payload)) |field| operand(func, field);
        },
    }
}

/// Whether a type is a type all the way down.
fn sound(comp: *const Compilation, index: Pool.Index, depth: u32) bool {
    // the parser bounds how deep a written type nests
    if (depth > 64) return false;
    if (index == .poison) return false;
    return switch (comp.pool.keyOf(index)) {
        .simple => index != .poison,
        .pointer => |pointer| sound(comp, pointer.child, depth + 1),
        .optional, .error_union => |child| sound(comp, child, depth + 1),
        // a struct's fields are its own instantiation's business
        .struct_type => true,
        // a value is not a type
        .int, .float, .error_value, .null_typed => false,
    };
}

fn operand(func: *const IR.Func, ref: IR.Ref) void {
    assert(ref != .none);
    switch (ref.unwrap()) {
        .inst => |index| assert(index.int() < func.insts.len),
        .constant => {},
    }
}
