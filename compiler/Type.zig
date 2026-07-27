//! Pure functions over `InternPool`, which does the storing.

const std = @import("std");
const Allocator = std.mem.Allocator;
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

/// Why a coercion was refused. The two need different words, the kinds not agreeing is
/// a mistake about types, and a literal not fitting is a mistake about one value.
pub const Refusal = error{ WrongType, OutOfRange };

pub const Coercion = enum {
    identity,
    int_widen,
    comptime_literal,
    from_never,
    pointer_to_readonly,
};

pub fn intRange(ty: Index) ?struct { min: i128, max: i128 } {
    const info = intInfo(ty) orelse return null;
    if (!info.signed) return .{ .min = 0, .max = (@as(i128, 1) << @intCast(info.bits)) - 1 };
    const limit = @as(i128, 1) << @intCast(info.bits - 1);
    return .{ .min = -limit, .max = limit - 1 };
}

/// `value` is the source's comptime value where it has one, since a literal has to fit
/// the type it becomes as well as agree with it in kind.
pub fn coerce(
    pool: *const InternPool,
    source: Index,
    destination: Index,
    value: ?i128,
) Refusal!Coercion {
    if (source == destination) return .identity;
    if (source == .never) return .from_never;

    if (source == .comptime_int and (isInteger(destination) or isFloat(destination))) {
        if (value) |literal| if (intRange(destination)) |range| {
            if (literal < range.min or literal > range.max) return error.OutOfRange;
        };
        return .comptime_literal;
    }
    if (source == .comptime_float and isFloat(destination)) return .comptime_literal;

    if (intInfo(source)) |from| if (intInfo(destination)) |into| {
        const fits = if (from.signed == into.signed)
            into.bits >= from.bits
        else if (into.signed)
            into.bits > from.bits // an unsigned source needs a spare sign bit
        else
            false; // a signed source never fits an unsigned destination
        return if (fits) .int_widen else error.WrongType;
    };

    switch (pool.keyOf(source)) {
        .pointer => |from| switch (pool.keyOf(destination)) {
            .pointer => |into| {
                if (from.pointee != into.pointee) return error.WrongType;
                // Giving up the right to write is safe. Gaining it never is.
                const gives_up_writing = from.is_mutable and !into.is_mutable;
                return if (gives_up_writing) .pointer_to_readonly else error.WrongType;
            },
            else => return error.WrongType,
        },
        else => return error.WrongType,
    }
}

/// Whether `Arena.copy` can duplicate everything the value owns: a flat type trivially,
/// and `str`, whose characters it copies. A type holding a pointer cannot be, since the
/// copy would be relabelled without moving what it reaches.
pub fn isCopyable(pool: *const InternPool, ty: Index) bool {
    return ty == .str or pool.isFlat(ty);
}

// Literals

pub const Number = union(enum) { int: i128, float: f64 };

/// The tokenizer accepts more than is valid, so a bad literal is caught here.
pub fn parseNumber(text: []const u8) error{ InvalidDigit, TooLarge }!Number {
    if (isFloatLiteral(text)) {
        const value = std.fmt.parseFloat(f64, text) catch return error.InvalidDigit;
        return .{ .float = value };
    }
    const value = std.fmt.parseInt(i128, text, 0) catch |err| return switch (err) {
        error.Overflow => error.TooLarge,
        error.InvalidCharacter => error.InvalidDigit,
    };
    return .{ .int = value };
}

/// The one place a literal's shape becomes a type.
pub fn numberType(number: Number) Index {
    return switch (number) {
        .int => .comptime_int,
        .float => .comptime_float,
    };
}

/// Base dependent: `e` is an exponent in decimal but a digit in hex, where `p` marks it.
fn isFloatLiteral(text: []const u8) bool {
    if (text.len > 1 and text[0] == '0') switch (text[1]) {
        'x', 'X' => return containsAny(text, ".pP"),
        'b', 'B', 'o', 'O' => return false,
        else => {},
    };
    return containsAny(text, ".eE");
}

fn containsAny(text: []const u8, set: []const u8) bool {
    return std.mem.indexOfAny(u8, text, set) != null;
}

/// Writes `ty` as a programmer would read it back.
pub fn spell(pool: *const InternPool, ty: Index, arena: Allocator) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    write(pool, ty, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn write(pool: *const InternPool, ty: Index, out: *Io.Writer) Io.Writer.Error!void {
    if (InternPool.builtinName(ty)) |name| return out.writeAll(name);

    switch (pool.keyOf(ty)) {
        .builtin => unreachable, // always has a name
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
