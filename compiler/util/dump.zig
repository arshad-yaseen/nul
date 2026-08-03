const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

const AST = @import("../AST.zig");
const Compilation = @import("../Compilation.zig");
const IR = @import("../IR.zig");
const Pool = @import("../Pool.zig");
const spell = @import("spell.zig");

const Node = AST.Node;

/// Far above anything `Parse` can build.
const depth_max = 1024;

pub fn tree(t: AST, writer: *Writer) Writer.Error!void {
    assert(t.nodes.len > 0);
    assert(t.nodeTag(.root) == .root);
    try node(t, writer, .root, 0, "");
}

fn node(
    ast: AST,
    writer: *Writer,
    index: Node.Index,
    depth: u32,
    role: []const u8,
) Writer.Error!void {
    assert(index.int() < ast.nodes.len);

    try writer.splatByteAll(' ', depth * 2);
    if (role.len > 0) try writer.print("{s}: ", .{role});
    if (depth >= depth_max) return writer.writeAll("...\n");

    const view = ast.viewOf(index);
    try writer.writeAll(@tagName(view));

    const below = depth + 1;
    switch (view) {
        .root, .block, .struct_literal => |children| {
            try writer.writeByte('\n');
            for (children) |child| try node(ast, writer, child, below, "");
        },
        .error_decl => |it| {
            try writer.print(" {s}", .{ast.tokenSlice(it.name_token)});
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(ast, writer, index, below);
        },
        .use_decl => |it| {
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(ast, writer, index, below);
            try node(ast, writer, it.path, below, "path");
        },
        .struct_decl => |it| {
            try writer.print(" {s}", .{ast.tokenSlice(it.name_token)});
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(ast, writer, index, below);
            for (it.type_params) |param| try node(ast, writer, param, below, "");
            for (it.members) |member| try node(ast, writer, member, below, "");
        },
        .type_decl => |it| {
            try writer.print(" {s}", .{ast.tokenSlice(it.name_token)});
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(ast, writer, index, below);
            try node(ast, writer, it.aliased, below, "type");
        },
        .fn_decl => |it| {
            try writer.print(" {s}", .{ast.tokenSlice(it.name_token)});
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(ast, writer, index, below);
            for (it.type_params) |param| try node(ast, writer, param, below, "");
            for (it.params) |param| try node(ast, writer, param, below, "");
            if (it.return_type.unwrap()) |returned| try node(ast, writer, returned, below, "ret");
            try node(ast, writer, it.body, below, "body");
        },
        .var_decl => |it| {
            const keyword = if (it.is_mutable) "var" else "let";
            try writer.print(" {s} {s}", .{ ast.tokenSlice(it.name_token), keyword });
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(ast, writer, index, below);
            if (it.type_expr.unwrap()) |declared| try node(ast, writer, declared, below, "type");
            try node(ast, writer, it.init_expr, below, "init");
        },
        .type_param, .capture => |token| {
            try writer.print(" {s}\n", .{ast.tokenSlice(token)});
        },
        .param, .field => |it| {
            try writer.print(" {s}\n", .{ast.tokenSlice(it.name_token)});
            try docs(ast, writer, index, below);
            try node(ast, writer, it.type_expr, below, "type");
        },

        .assign, .orelse_expr => |it| {
            try writer.writeByte('\n');
            try node(ast, writer, it.lhs, below, "lhs");
            try node(ast, writer, it.rhs, below, "rhs");
        },
        .if_expr => |it| {
            try writer.writeByte('\n');
            try node(ast, writer, it.cond, below, "cond");
            if (it.capture.unwrap()) |bound| try node(ast, writer, bound, below, "capture");
            try node(ast, writer, it.then_block, below, "then");
            if (it.else_node.unwrap()) |otherwise| try node(ast, writer, otherwise, below, "else");
        },
        .while_stmt => |it| {
            try writer.writeByte('\n');
            if (it.cond.unwrap()) |cond| try node(ast, writer, cond, below, "cond");
            if (it.capture.unwrap()) |capture| try node(ast, writer, capture, below, "capture");
            try node(ast, writer, it.body, below, "body");
        },
        .break_expr, .continue_expr, .null_literal, .err => {
            try writer.writeByte('\n');
        },
        .return_expr => |operand| {
            try writer.writeByte('\n');
            if (operand.unwrap()) |value| try node(ast, writer, value, below, "value");
        },

        .ident, .number_literal => |token| {
            try writer.print(" {s}\n", .{ast.tokenSlice(token)});
        },
        .bool_literal => |it| try writer.print(" {s}\n", .{if (it.value) "true" else "false"}),

        .field_access => |it| {
            try writer.print(" {s}\n", .{ast.tokenSlice(it.name_token)});
            try node(ast, writer, it.lhs, below, "lhs");
        },
        .instance => |it| {
            try writer.writeByte('\n');
            try node(ast, writer, it.base, below, "base");
            for (it.args) |arg| try node(ast, writer, arg, below, "arg");
        },
        .call => |it| {
            try writer.writeByte('\n');
            try node(ast, writer, it.callee, below, "callee");
            for (it.args) |arg| try node(ast, writer, arg, below, "arg");
        },
        .struct_field_init => |it| {
            try writer.print(" {s}\n", .{ast.tokenSlice(it.name_token)});
            try node(ast, writer, it.value, below, "value");
        },
        .catch_expr => |it| {
            try writer.writeByte('\n');
            try node(ast, writer, it.lhs, below, "lhs");
            if (it.capture.unwrap()) |bound| try node(ast, writer, bound, below, "capture");
            try node(ast, writer, it.rhs, below, "rhs");
        },
        .binary => |it| {
            try writer.print(" {t}\n", .{it.op});
            try node(ast, writer, it.lhs, below, "lhs");
            try node(ast, writer, it.rhs, below, "rhs");
        },
        .unary => |it| {
            try writer.print(" {t}\n", .{it.op});
            try node(ast, writer, it.operand, below, "operand");
        },
        .pointer_type => |it| {
            try flag(writer, it.is_mutable, "var");
            try writer.writeByte('\n');
            try node(ast, writer, it.child, below, "child");
        },
        .defer_stmt, .try_expr, .optional_type, .error_union_type => |child| {
            try writer.writeByte('\n');
            try node(ast, writer, child, below, "child");
        },
    }
}

fn docs(ast: AST, writer: *Writer, index: Node.Index, depth: u32) Writer.Error!void {
    assert(index.int() < ast.nodes.len);

    for (ast.docsAbove(index)) |comment| {
        try writer.splatByteAll(' ', depth * 2);
        try writer.print("doc {s}\n", .{ast.commentText(comment)});
    }
}

fn flag(writer: *Writer, set: bool, name: []const u8) Writer.Error!void {
    assert(name.len > 0);
    assert(name.len < 8);
    if (set) try writer.print(" {s}", .{name});
}

// the IR dump

pub fn func(comp: *const Compilation, body: *const IR.Func, writer: *Writer) Writer.Error!void {
    assert(body.blocks.len > 0);

    try writer.writeAll("fn ");
    try spell.writeInstance(comp, writer, body.instance);
    try spell.writeSignature(comp, writer, body.instance);
    try writer.writeByte('\n');

    for (body.blocks, 0..) |block, block_index| {
        assert(block.terminator != .none);
        try writer.print("b{d}:\n", .{block_index});

        for (block.first..block.end()) |raw| {
            const index: IR.Inst.Index = .from(raw);
            try inst(comp, body, index, writer);
        }
        try terminator(comp, block.terminator, writer);
    }
}

fn inst(
    comp: *const Compilation,
    body: *const IR.Func,
    index: IR.Inst.Index,
    writer: *Writer,
) Writer.Error!void {
    assert(index.int() < body.insts.len);

    const tag = body.insts.items(.tag)[index.int()];
    const data = body.insts.items(.data)[index.int()];
    const type_index = body.insts.items(.type)[index.int()];

    try writer.print("  %{d} = {t}", .{ index.int(), tag });
    switch (tag) {
        .param, .local => {
            if (data.name != .empty) try writer.print(" {s}", .{comp.pool.stringText(data.name)});
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
        .scope_end,
        => {
            try writer.writeByte(' ');
            try ref(comp, data.un, writer);
        },
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
            try writer.writeByte(' ');
            try ref(comp, data.bin.lhs, writer);
            try writer.writeAll(", ");
            try ref(comp, data.bin.rhs, writer);
        },
        .field_ptr, .field_val => {
            try writer.writeByte(' ');
            try ref(comp, data.field.base, writer);
            try writer.print(", .{s}", .{comp.rowName(data.field.row)});
        },
        .call => {
            const call = body.callAt(data.payload);
            try writer.writeByte(' ');
            try spell.writeInstance(comp, writer, call.callee);
            try writer.writeByte('(');
            for (call.args, 0..) |operand, position| {
                if (position > 0) try writer.writeAll(", ");
                try ref(comp, operand, writer);
            }
            try writer.writeByte(')');
        },
        .struct_init => {
            const rows = comp.instanceAt(comp.pool.keyOf(type_index).type_struct).rows;
            try writer.writeAll(" .{ ");
            for (body.structInitAt(data.payload), 0..) |operand, position| {
                if (position > 0) try writer.writeAll(", ");
                try writer.print("{s}: ", .{comp.rowName(rows.at(@intCast(position)))});
                try ref(comp, operand, writer);
            }
            try writer.writeAll(" }");
        },
        .arena_init, .scope_begin => {},
    }

    if (type_index != .void_type) {
        try writer.writeAll(" : ");
        try spell.writeType(comp, writer, type_index);
    }
    try writer.writeByte('\n');
}

fn ref(comp: *const Compilation, operand: IR.Ref, writer: *Writer) Writer.Error!void {
    assert(operand != .none);
    switch (operand.unwrap()) {
        .inst => |index| try writer.print("%{d}", .{index.int()}),
        .constant => |value| try spell.writeConstant(comp, writer, value),
    }
}

fn terminator(
    comp: *const Compilation,
    term: IR.Terminator,
    writer: *Writer,
) Writer.Error!void {
    switch (term) {
        // `finish` leaves every surviving block a terminator
        .none => unreachable,
        .jump => |target| try writer.print("  jump b{d}\n", .{target.int()}),
        .branch => |branch| {
            try writer.writeAll("  branch ");
            try ref(comp, branch.cond, writer);
            try writer.print(", b{d}, b{d}\n", .{
                branch.then_block.int(),
                branch.else_block.int(),
            });
        },
        .ret => |value| {
            if (value == .none) {
                try writer.writeAll("  return\n");
            } else {
                try writer.writeAll("  return ");
                try ref(comp, value, writer);
                try writer.writeByte('\n');
            }
        },
    }
}
