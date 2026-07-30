const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

const AST = @import("../AST.zig");
const Node = AST.Node;

/// Far above anything `Parse` can build, so the dump is total for any tree.
const depth_max = 1024;

pub fn dump(tree: AST, writer: *Writer) Writer.Error!void {
    assert(tree.nodes.len > 0);
    assert(tree.nodeTag(.root) == .root);
    try node(tree, writer, .root, 0, "");
}

fn node(
    tree: AST,
    writer: *Writer,
    index: Node.Index,
    depth: u32,
    role: []const u8,
) Writer.Error!void {
    assert(index.int() < tree.nodes.len);

    try writer.splatByteAll(' ', depth * 2);
    if (role.len > 0) try writer.print("{s}: ", .{role});
    if (depth >= depth_max) return writer.writeAll("...\n");

    const view = tree.viewOf(index);
    try writer.writeAll(@tagName(view));

    const below = depth + 1;
    switch (view) {
        .root, .block, .struct_literal => |children| {
            try writer.writeByte('\n');
            for (children) |child| try node(tree, writer, child, below, "");
        },
        .use_decl => |it| {
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(tree, writer, index, below);
            try node(tree, writer, it.path, below, "path");
        },
        .struct_decl => |it| {
            try writer.print(" {s}", .{tree.tokenSlice(it.name_token)});
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(tree, writer, index, below);
            for (it.type_params) |param| try node(tree, writer, param, below, "");
            for (it.members) |member| try node(tree, writer, member, below, "");
        },
        .type_decl => |it| {
            try writer.print(" {s}", .{tree.tokenSlice(it.name_token)});
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(tree, writer, index, below);
            try node(tree, writer, it.aliased, below, "type");
        },
        .fn_decl => |it| {
            try writer.print(" {s}", .{tree.tokenSlice(it.name_token)});
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(tree, writer, index, below);
            for (it.type_params) |param| try node(tree, writer, param, below, "");
            for (it.params) |param| try node(tree, writer, param, below, "");
            if (it.return_type.unwrap()) |returned| try node(tree, writer, returned, below, "ret");
            try node(tree, writer, it.body, below, "body");
        },
        .var_decl => |it| {
            const keyword = if (it.is_mutable) "var" else "let";
            try writer.print(" {s} {s}", .{ tree.tokenSlice(it.name_token), keyword });
            try flag(writer, it.is_pub, "pub");
            try writer.writeByte('\n');
            try docs(tree, writer, index, below);
            if (it.type_expr.unwrap()) |declared| try node(tree, writer, declared, below, "type");
            try node(tree, writer, it.init_expr, below, "init");
        },
        .type_param, .capture, .error_value => |token| {
            try writer.print(" {s}\n", .{tree.tokenSlice(token)});
        },
        .param, .field => |it| {
            try writer.print(" {s}\n", .{tree.tokenSlice(it.name_token)});
            try docs(tree, writer, index, below);
            try node(tree, writer, it.type_expr, below, "type");
        },

        .assign, .orelse_expr => |it| {
            try writer.writeByte('\n');
            try node(tree, writer, it.lhs, below, "lhs");
            try node(tree, writer, it.rhs, below, "rhs");
        },
        .if_stmt => |it| {
            try writer.writeByte('\n');
            try node(tree, writer, it.cond, below, "cond");
            if (it.capture.unwrap()) |bound| try node(tree, writer, bound, below, "capture");
            try node(tree, writer, it.then_block, below, "then");
            if (it.else_node.unwrap()) |otherwise| try node(tree, writer, otherwise, below, "else");
        },
        .while_stmt => |it| {
            try writer.writeByte('\n');
            if (it.cond.unwrap()) |cond| try node(tree, writer, cond, below, "cond");
            try node(tree, writer, it.body, below, "body");
        },
        .break_stmt, .continue_stmt, .null_literal, .err => {
            try writer.writeByte('\n');
        },
        .return_stmt => |operand| {
            try writer.writeByte('\n');
            if (operand.unwrap()) |value| try node(tree, writer, value, below, "value");
        },

        .ident, .number_literal, .str_literal => |token| {
            try writer.print(" {s}\n", .{tree.tokenSlice(token)});
        },
        .bool_literal => |it| try writer.print(" {s}\n", .{if (it.value) "true" else "false"}),

        .field_access => |it| {
            try writer.print(" {s}\n", .{tree.tokenSlice(it.name_token)});
            try node(tree, writer, it.lhs, below, "lhs");
        },
        .instance => |it| {
            try writer.writeByte('\n');
            try node(tree, writer, it.base, below, "base");
            for (it.args) |arg| try node(tree, writer, arg, below, "arg");
        },
        .call => |it| {
            try writer.writeByte('\n');
            try node(tree, writer, it.callee, below, "callee");
            for (it.args) |arg| try node(tree, writer, arg, below, "arg");
        },
        .struct_field_init => |it| {
            try writer.print(" {s}\n", .{tree.tokenSlice(it.name_token)});
            try node(tree, writer, it.value, below, "value");
        },
        .catch_expr => |it| {
            try writer.writeByte('\n');
            try node(tree, writer, it.lhs, below, "lhs");
            if (it.capture.unwrap()) |bound| try node(tree, writer, bound, below, "capture");
            try node(tree, writer, it.rhs, below, "rhs");
        },
        .binary => |it| {
            try writer.print(" {t}\n", .{it.op});
            try node(tree, writer, it.lhs, below, "lhs");
            try node(tree, writer, it.rhs, below, "rhs");
        },
        .unary => |it| {
            try writer.print(" {t}\n", .{it.op});
            try node(tree, writer, it.operand, below, "operand");
        },
        .pointer_type => |it| {
            try flag(writer, it.is_mutable, "var");
            try writer.writeByte('\n');
            try node(tree, writer, it.child, below, "child");
        },
        .defer_stmt, .try_expr, .grouped, .optional_type, .error_union_type => |child| {
            try writer.writeByte('\n');
            try node(tree, writer, child, below, "child");
        },
    }
}

fn docs(tree: AST, writer: *Writer, index: Node.Index, depth: u32) Writer.Error!void {
    assert(index.int() < tree.nodes.len);

    var token = tree.docComment(index) orelse return;
    assert(tree.tokenTag(token) == .doc_comment);

    while (tree.tokenTag(token) == .doc_comment) : (token = token.after(1)) {
        try writer.splatByteAll(' ', depth * 2);
        try writer.print("doc {s}\n", .{tree.tokenSlice(token)});
    }
}

fn flag(writer: *Writer, set: bool, name: []const u8) Writer.Error!void {
    assert(name.len > 0);
    assert(name.len < 8);
    if (set) try writer.print(" {s}", .{name});
}
