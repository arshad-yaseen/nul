//! The type system's relations, in one place: what coerces to what, the type two
//! operands settle on, and what an operator accepts. Pure functions over `InternPool`,
//! which does the storing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Comptime = @import("Comptime.zig");
const InternPool = @import("InternPool.zig");
const Value = Comptime.Value;

pub const Index = InternPool.Index;

pub fn pointeeOf(pool: *const InternPool, ty: Index) ?Index {
    return switch (pool.keyOf(ty)) {
        .pointer => |pointer| pointer.pointee,
        else => null,
    };
}

// Classification

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
    return ty == .f32 or ty == .f64 or ty == .comptime_float;
}

pub fn isNumber(ty: Index) bool {
    return ty == .comptime_int or isInteger(ty) or isFloat(ty);
}

pub fn isUnsignedInt(ty: Index) bool {
    return switch (ty) {
        .u8, .u16, .u32, .u64, .usize => true,
        else => false,
    };
}

pub fn canEqual(pool: *const InternPool, ty: Index) bool {
    return isNumber(ty) or ty == .bool or pool.keyOf(ty) == .pointer;
}

pub fn intRange(ty: Index) ?struct { min: i128, max: i128 } {
    const info = intInfo(ty) orelse return null;
    if (!info.signed) return .{ .min = 0, .max = (@as(i128, 1) << @intCast(info.bits)) - 1 };
    const limit = @as(i128, 1) << @intCast(info.bits - 1);
    return .{ .min = -limit, .max = limit - 1 };
}

/// The type a comptime value takes when it has to live in runtime memory.
pub fn runtime(ty: Index) Index {
    return switch (ty) {
        .comptime_int => .i64,
        .comptime_float => .f64,
        else => ty,
    };
}

// Coercion

/// Why a coercion was refused. The two need different words: the kinds not agreeing is
/// a mistake about types, and a value not fitting is a mistake about one value.
pub const Refusal = error{ WrongType, OutOfRange };

/// Whether `source` reaches `destination` without changing meaning. `val` is the
/// source's comptime value where it has one, since a known value has to fit the type it
/// becomes as well as agree with it in kind.
pub fn coerce(pool: *const InternPool, source: Index, destination: Index, val: Value) Refusal!void {
    if (source == destination) return;
    if (source == .never) return;

    // A known integer coerces wherever it fits, whatever width it started at.
    if ((val == .int and isInteger(source)) or source == .comptime_int) {
        if (isInteger(destination) or isFloat(destination)) return valueFits(val, destination);
    }
    if (source == .comptime_float and isFloat(destination)) return;

    if (intInfo(source)) |from| if (intInfo(destination)) |into| {
        const fits = if (from.signed == into.signed)
            into.bits >= from.bits
        else if (into.signed)
            into.bits > from.bits // an unsigned source needs a spare sign bit
        else
            false; // a signed source never fits an unsigned destination
        if (!fits) return error.WrongType;
        return;
    };

    switch (pool.keyOf(source)) {
        .pointer => |from| switch (pool.keyOf(destination)) {
            .pointer => |into| {
                if (from.pointee != into.pointee) return error.WrongType;
                // Giving up the right to write is safe. Gaining it never is.
                if (from.is_mutable and !into.is_mutable) return;
                return error.WrongType;
            },
            else => return error.WrongType,
        },
        else => return error.WrongType,
    }
}

/// `usize` and `isize` have no range yet, but an unsigned type of any width holds
/// nothing negative.
fn valueFits(val: Value, destination: Index) Refusal!void {
    if (val != .int) return;
    if (intRange(destination)) |range| {
        if (val.int < range.min or val.int > range.max) return error.OutOfRange;
    } else if (isUnsignedInt(destination) and val.int < 0) {
        return error.OutOfRange;
    }
}

/// The type two operands settle on, or null when neither reaches the other. Values are
/// not consulted here; whether each side fits the peer is its own check.
pub fn peer(pool: *const InternPool, a: Index, b: Index) ?Index {
    if (a == .poisoned or b == .poisoned) return .poisoned;
    if (coerce(pool, a, b, .unknown)) |_| return b else |_| {}
    if (coerce(pool, b, a, .unknown)) |_| return a else |_| {}
    return null;
}

/// Whether `Arena.copy` can duplicate everything the value owns: a flat type trivially,
/// and `str`, whose characters it copies. A type holding a pointer cannot be, since the
/// copy would be relabelled without moving what it reaches.
pub fn isCopyable(pool: *const InternPool, ty: Index) bool {
    return ty == .str or pool.isFlat(ty);
}

// Naming

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
