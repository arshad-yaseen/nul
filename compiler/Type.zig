//! Pure functions over `InternPool`, which does the storing.

const std = @import("std");
const Io = std.Io;

const InternPool = @import("InternPool.zig");

pub const Index = InternPool.Index;

pub fn pointeeOf(pool: *const InternPool, ty: Index) ?Index {
    return switch (pool.keyOf(ty)) {
        .pointer => |pointer| pointer.pointee,
        else => null,
    };
}

// Coercion

fn intInfo(ty: Index) ?struct { signed: bool, bits: u16 } {
    return switch (ty) {
        .i8 => .{ .signed = true, .bits = 8 },
        .i16 => .{ .signed = true, .bits = 16 },
        .i32 => .{ .signed = true, .bits = 32 },
        .i64 => .{ .signed = true, .bits = 64 },
        .u8 => .{ .signed = false, .bits = 8 },
        .u16 => .{ .signed = false, .bits = 16 },
        .u32 => .{ .signed = false, .bits = 32 },
        .u64 => .{ .signed = false, .bits = 64 },
        else => null,
    };
}

fn isInteger(ty: Index) bool {
    return ty == .usize or ty == .isize or intInfo(ty) != null;
}

fn isFloat(ty: Index) bool {
    return ty == .f32 or ty == .f64;
}

/// Sema needs which one, not just whether, some change representation and must emit an
/// instruction, others are a relabelling that must not.
pub const Coercion = enum {
    identity,
    int_widen,
    /// Whether the *value* fits is Sema's to check, it holds the value, this does not.
    comptime_literal,
    from_never,
    pointer_to_readonly,
};

pub fn coerce(pool: *const InternPool, source: Index, destination: Index) ?Coercion {
    if (source == destination) return .identity;
    if (source == .never) return .from_never;

    // A literal has no type of its own yet, so the destination decides.
    if (source == .comptime_int and (isInteger(destination) or isFloat(destination)))
        return .comptime_literal;
    if (source == .comptime_float and isFloat(destination)) return .comptime_literal;

    if (intInfo(source)) |from| if (intInfo(destination)) |into| {
        const fits = if (from.signed == into.signed)
            into.bits >= from.bits
        else if (into.signed)
            into.bits > from.bits // an unsigned source needs a spare sign bit
        else
            false; // a signed source never fits an unsigned destination
        return if (fits) .int_widen else null;
    };

    switch (pool.keyOf(source)) {
        .pointer => |from| switch (pool.keyOf(destination)) {
            .pointer => |into| {
                if (from.pointee != into.pointee) return null;
                // Giving up the right to write is safe. Gaining it never is.
                const gives_up_writing = from.is_mutable and !into.is_mutable;
                return if (gives_up_writing) .pointer_to_readonly else null;
            },
            else => return null,
        },
        else => return null,
    }
}

/// Writes `ty` as a programmer would read it back.
pub fn write(pool: *const InternPool, ty: Index, out: *Io.Writer) Io.Writer.Error!void {
    if (InternPool.builtinName(ty)) |name| return out.writeAll(name);

    switch (pool.keyOf(ty)) {
        .builtin => unreachable, // a builtin always has a name, so it never reaches here
        .pointer => |pointer| {
            try out.writeAll(if (pointer.is_mutable) "*var " else "*");
            try write(pool, pointer.pointee, out);
        },
        .struct_type => try out.writeAll(pool.stringBytes(pool.structName(ty))),
        .func => |func| {
            try out.writeAll("fn(");
            for (func.params, 0..) |param, position| {
                if (position > 0) try out.writeAll(", ");
                try write(pool, param, out);
            }
            try out.writeAll(") ");
            try write(pool, func.return_type, out);
        },
    }
}
