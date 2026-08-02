//! How a diagnostic or a dump names what the tables hold.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

const Compilation = @import("../Compilation.zig");
const Pool = @import("../Pool.zig");

pub fn writeType(comp: *const Compilation, writer: *Writer, index: Pool.Index) Writer.Error!void {
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
            .struct_type => |instance| return writeInstance(comp, writer, instance),
            .int, .float, .error_value, .null_typed => unreachable,
        }
    }
    try writer.writeAll("...");
}

/// `Box[i64]`, or `Arena.copy[Pair]` for a member.
pub fn writeInstance(
    comp: *const Compilation,
    writer: *Writer,
    index: Pool.Instance,
) Writer.Error!void {
    const instance = comp.instanceAt(index);
    const decl = comp.declAt(instance.decl);
    const args = comp.instanceArgs(index);

    var skip: usize = 0;
    if (decl.owner.unwrap()) |owner_index| {
        const owner = comp.declAt(owner_index);
        try writer.writeAll(comp.pool.stringText(owner.name));
        // the owner's parameters lead the argument list
        const owner_params = comp.typeParamCount(owner_index);
        skip = @min(owner_params, args.len);
        try writeArgs(comp, writer, args[0..skip]);
        try writer.writeByte('.');
    }
    try writer.writeAll(comp.pool.stringText(decl.name));
    try writeArgs(comp, writer, args[skip..]);
}

pub fn writeArgs(
    comp: *const Compilation,
    writer: *Writer,
    args: []const Pool.Index,
) Writer.Error!void {
    if (args.len == 0) return;
    try writer.writeByte('[');
    for (args, 0..) |arg, position| {
        if (position > 0) try writer.writeAll(", ");
        if (comp.pool.isType(arg)) {
            try writeType(comp, writer, arg);
        } else {
            try writeConstant(comp, writer, arg);
        }
    }
    try writer.writeByte(']');
}

/// `(a: i64, b: bool) i64`, for the IR header.
pub fn writeSignature(
    comp: *const Compilation,
    writer: *Writer,
    index: Pool.Instance,
) Writer.Error!void {
    const instance = comp.instanceAt(index);
    assert(instance.rows_state == .done or instance.rows_state == .poisoned);

    try writer.writeByte('(');
    for (comp.instanceRows(index), 0..) |row, position| {
        if (position > 0) try writer.writeAll(", ");
        try writer.print("{s}: ", .{comp.pool.stringText(row.name)});
        try writeType(comp, writer, row.type);
    }
    try writer.writeByte(')');
    if (instance.type != .nothing_type) {
        try writer.writeByte(' ');
        try writeType(comp, writer, instance.type);
    }
}

pub fn writeConstant(
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
                try writeType(comp, writer, it.type);
            }
        },
        .float => |it| {
            try writer.print("{d}", .{it.value});
            if (it.type != .untyped_float_type) {
                try writer.writeByte(':');
                try writeType(comp, writer, it.type);
            }
        },
        .error_value => |declared| try writer.writeAll(
            comp.pool.stringText(comp.declAt(declared).name),
        ),
        .null_typed => try writer.writeAll("null"),
        .pointer, .optional, .error_union, .struct_type => unreachable,
    }
}

pub fn writeConstantBare(
    comp: *const Compilation,
    writer: *Writer,
    value: Pool.Index,
) Writer.Error!void {
    switch (comp.pool.keyOf(value)) {
        .int => |it| try writer.print("{d}", .{it.value}),
        .float => |it| try writer.print("{d}", .{it.value}),
        else => try writeConstant(comp, writer, value),
    }
}
