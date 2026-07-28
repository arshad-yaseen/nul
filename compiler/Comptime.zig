//! The compile-time value system. A `Value` is what the compiler knows about a value
//! before the program runs, it is parsed here, folded here, and carried on instructions
//! and declarations so that knowledge flows wherever the value does.

const std = @import("std");

const Ast = @import("Ast.zig");
const InternPool = @import("InternPool.zig");

/// `unknown` is a runtime value. Everything else the compiler can act on.
pub const Value = union(enum) {
    unknown,
    int: i128,
    float: f64,
    bool: bool,
    type: InternPool.Index,
};

/// A value with the type it has, which is how one travels.
pub const TypedValue = struct {
    ty: InternPool.Index,
    val: Value = .unknown,

    pub const poisoned: TypedValue = .{ .ty = .poisoned };
};

pub const ParseError = error{ InvalidDigit, TooLarge };

/// The tokenizer accepts more than is valid, so a bad literal is caught here.
pub fn parse(text: []const u8) ParseError!Value {
    if (isFloatLiteral(text)) {
        return .{ .float = std.fmt.parseFloat(f64, text) catch return error.InvalidDigit };
    }
    const value = std.fmt.parseInt(i128, text, 0) catch |err| return switch (err) {
        error.Overflow => error.TooLarge,
        error.InvalidCharacter => error.InvalidDigit,
    };
    return .{ .int = value };
}

/// The type a literal starts as.
pub fn typeOf(val: Value) InternPool.Index {
    return switch (val) {
        .int => .comptime_int,
        .float => .comptime_float,
        .bool => .bool,
        .type => .type,
        .unknown => unreachable,
    };
}

/// Base dependent: `e` is an exponent in decimal but a digit in hex, where `p` marks it.
fn isFloatLiteral(text: []const u8) bool {
    if (text.len > 1 and text[0] == '0') switch (text[1]) {
        'x', 'X' => return std.mem.indexOfAny(u8, text, ".pP") != null,
        'b', 'B', 'o', 'O' => return false,
        else => {},
    };
    return std.mem.indexOfAny(u8, text, ".eE") != null;
}

// Folding

/// Comptime integers are `i128`: wide enough for every sized integer, and a fold past
/// the edge reports rather than wraps.
pub const FoldError = error{ DivisionByZero, Overflow };

/// Operand kinds are checked before folding, so a mismatch here means an operand was
/// already reported; it folds to `unknown` rather than crashing the compiler.
pub fn fold(op: Ast.BinaryOp, a: Value, b: Value) FoldError!Value {
    if (a == .unknown or b == .unknown) return .unknown;

    if (a == .bool and b == .bool) return switch (op) {
        .bool_and => .{ .bool = a.bool and b.bool },
        .bool_or => .{ .bool = a.bool or b.bool },
        .equal => .{ .bool = a.bool == b.bool },
        .not_equal => .{ .bool = a.bool != b.bool },
        else => .unknown,
    };

    if (a == .float or b == .float) {
        const x = toFloat(a) orelse return .unknown;
        const y = toFloat(b) orelse return .unknown;
        return switch (op) {
            .add => .{ .float = x + y },
            .sub => .{ .float = x - y },
            .mul => .{ .float = x * y },
            .div => if (y == 0) error.DivisionByZero else .{ .float = x / y },
            .mod => if (y == 0) error.DivisionByZero else .{ .float = @mod(x, y) },
            .equal => .{ .bool = x == y },
            .not_equal => .{ .bool = x != y },
            .less_than => .{ .bool = x < y },
            .less_or_equal => .{ .bool = x <= y },
            .greater_than => .{ .bool = x > y },
            .greater_or_equal => .{ .bool = x >= y },
            .bool_and, .bool_or => .unknown,
        };
    }

    if (a != .int or b != .int) return .unknown;
    const x = a.int;
    const y = b.int;
    return switch (op) {
        .add => .{ .int = std.math.add(i128, x, y) catch return error.Overflow },
        .sub => .{ .int = std.math.sub(i128, x, y) catch return error.Overflow },
        .mul => .{ .int = std.math.mul(i128, x, y) catch return error.Overflow },
        .div => .{ .int = std.math.divTrunc(i128, x, y) catch |err| return switch (err) {
            error.DivisionByZero => error.DivisionByZero,
            error.Overflow => error.Overflow,
        } },
        .mod => if (y == 0) error.DivisionByZero else .{ .int = if (y == -1) 0 else @rem(x, y) },
        .equal => .{ .bool = x == y },
        .not_equal => .{ .bool = x != y },
        .less_than => .{ .bool = x < y },
        .less_or_equal => .{ .bool = x <= y },
        .greater_than => .{ .bool = x > y },
        .greater_or_equal => .{ .bool = x >= y },
        .bool_and, .bool_or => .unknown,
    };
}

pub fn negate(val: Value) FoldError!Value {
    return switch (val) {
        .int => |x| .{ .int = std.math.negate(x) catch return error.Overflow },
        .float => |x| .{ .float = -x },
        else => .unknown,
    };
}

pub fn boolNot(val: Value) Value {
    return switch (val) {
        .bool => |x| .{ .bool = !x },
        else => .unknown,
    };
}

fn toFloat(val: Value) ?f64 {
    return switch (val) {
        .int => |x| @floatFromInt(x),
        .float => |x| x,
        else => null,
    };
}

test "literals parse into values" {
    try std.testing.expectEqual(Value{ .int = 255 }, try parse("0xff"));
    try std.testing.expectEqual(Value{ .float = 2.5 }, try parse("2.5"));
    try std.testing.expectError(error.TooLarge, parse("340282366920938463463374607431768211456"));
    try std.testing.expectError(error.InvalidDigit, parse("0b12"));
}

test "arithmetic folds, and the edges report" {
    try std.testing.expectEqual(Value{ .int = 256 }, try fold(.add, .{ .int = 255 }, .{ .int = 1 }));
    try std.testing.expectEqual(Value{ .float = 3.5 }, try fold(.add, .{ .int = 1 }, .{ .float = 2.5 }));
    try std.testing.expectEqual(Value{ .bool = true }, try fold(.less_than, .{ .int = 1 }, .{ .int = 2 }));
    try std.testing.expectEqual(Value.unknown, try fold(.add, .unknown, .{ .int = 1 }));
    try std.testing.expectError(error.DivisionByZero, fold(.div, .{ .int = 1 }, .{ .int = 0 }));
    try std.testing.expectError(error.Overflow, fold(.mul, .{ .int = std.math.maxInt(i128) }, .{ .int = 2 }));
    try std.testing.expectEqual(Value{ .int = 0 }, try fold(.mod, .{ .int = std.math.minInt(i128) }, .{ .int = -1 }));
}
