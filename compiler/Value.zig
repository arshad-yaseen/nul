//! What an expression yields, its type, and what the compiler knows of it before the
//! program runs.

const std = @import("std");

const Ast = @import("Ast.zig");
const Type = @import("Type.zig");

const Value = @This();

ty: Type.Index,
known: Known = .runtime,

/// The comptime half. `runtime` means only the running program will see it.
pub const Known = union(enum) {
    runtime,
    int: i128,
    float: f64,
    bool: bool,
    type: Type.Index,
};

/// What analysis yields once it has reported why it has no answer.
pub const poisoned: Value = .{ .ty = .poisoned };

pub fn ofType(ty: Type.Index) Value {
    if (ty == .poisoned) return .poisoned;
    return .{ .ty = .type, .known = .{ .type = ty } };
}

pub fn asType(value: Value) ?Type.Index {
    return switch (value.known) {
        .type => |ty| ty,
        else => null,
    };
}

pub fn isKnown(value: Value) bool {
    return value.known != .runtime;
}

// Literals

pub const ParseError = error{ InvalidDigit, TooLarge };

/// The tokenizer accepts more than is valid, so a bad literal is caught here.
pub fn parse(text: []const u8) ParseError!Value {
    if (isFloatLiteral(text)) {
        const x = std.fmt.parseFloat(f64, text) catch return error.InvalidDigit;
        return .{ .ty = .comptime_float, .known = .{ .float = x } };
    }
    const x = std.fmt.parseInt(i128, text, 0) catch |err| return switch (err) {
        error.Overflow => error.TooLarge,
        error.InvalidCharacter => error.InvalidDigit,
    };
    return .{ .ty = .comptime_int, .known = .{ .int = x } };
}

/// Base dependent. `e` is an exponent in decimal but a digit in hex, where `p` marks it.
fn isFloatLiteral(text: []const u8) bool {
    if (text.len > 1 and text[0] == '0') switch (text[1]) {
        'x', 'X' => return std.mem.indexOfAny(u8, text, ".pP") != null,
        'b', 'B', 'o', 'O' => return false,
        else => {},
    };
    return std.mem.indexOfAny(u8, text, ".eE") != null;
}

// Folding

/// Comptime integers are `i128`, so a fold past that edge reports rather than wraps.
pub const FoldError = error{ DivisionByZero, Overflow };

/// Kinds are checked before folding, so a mismatch here was already reported.
pub fn fold(op: Ast.BinaryOp, a: Known, b: Known) FoldError!Known {
    if (a == .runtime or b == .runtime) return .runtime;

    if (a == .bool and b == .bool) return switch (op) {
        .bool_and => .{ .bool = a.bool and b.bool },
        .bool_or => .{ .bool = a.bool or b.bool },
        .equal => .{ .bool = a.bool == b.bool },
        .not_equal => .{ .bool = a.bool != b.bool },
        else => .runtime,
    };

    if (a == .float or b == .float) {
        const x = toFloat(a) orelse return .runtime;
        const y = toFloat(b) orelse return .runtime;
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
            .bool_and, .bool_or => .runtime,
        };
    }

    if (a != .int or b != .int) return .runtime;
    const x = a.int;
    const y = b.int;
    return switch (op) {
        .add => .{ .int = std.math.add(i128, x, y) catch return error.Overflow },
        .sub => .{ .int = std.math.sub(i128, x, y) catch return error.Overflow },
        .mul => .{ .int = std.math.mul(i128, x, y) catch return error.Overflow },
        .div => .{ .int = try std.math.divTrunc(i128, x, y) },
        .mod => if (y == 0) error.DivisionByZero else .{ .int = if (y == -1) 0 else @rem(x, y) },
        .equal => .{ .bool = x == y },
        .not_equal => .{ .bool = x != y },
        .less_than => .{ .bool = x < y },
        .less_or_equal => .{ .bool = x <= y },
        .greater_than => .{ .bool = x > y },
        .greater_or_equal => .{ .bool = x >= y },
        .bool_and, .bool_or => .runtime,
    };
}

pub fn negate(known: Known) FoldError!Known {
    return switch (known) {
        .int => |x| .{ .int = std.math.negate(x) catch return error.Overflow },
        .float => |x| .{ .float = -x },
        else => .runtime,
    };
}

pub fn boolNot(known: Known) Known {
    return switch (known) {
        .bool => |x| .{ .bool = !x },
        else => .runtime,
    };
}

fn toFloat(known: Known) ?f64 {
    return switch (known) {
        .int => |x| @floatFromInt(x),
        .float => |x| x,
        else => null,
    };
}

test "literals parse into values" {
    try std.testing.expectEqual(Value{ .ty = .comptime_int, .known = .{ .int = 255 } }, try parse("0xff"));
    try std.testing.expectEqual(Value{ .ty = .comptime_float, .known = .{ .float = 2.5 } }, try parse("2.5"));
    try std.testing.expectError(error.TooLarge, parse("340282366920938463463374607431768211456"));
    try std.testing.expectError(error.InvalidDigit, parse("0b12"));
}

test "arithmetic folds, and the edges report" {
    try std.testing.expectEqual(Known{ .int = 256 }, try fold(.add, .{ .int = 255 }, .{ .int = 1 }));
    try std.testing.expectEqual(Known{ .float = 3.5 }, try fold(.add, .{ .int = 1 }, .{ .float = 2.5 }));
    try std.testing.expectEqual(Known{ .bool = true }, try fold(.less_than, .{ .int = 1 }, .{ .int = 2 }));
    try std.testing.expectEqual(Known.runtime, try fold(.add, .runtime, .{ .int = 1 }));
    try std.testing.expectError(error.DivisionByZero, fold(.div, .{ .int = 1 }, .{ .int = 0 }));
    try std.testing.expectError(error.Overflow, fold(.mul, .{ .int = std.math.maxInt(i128) }, .{ .int = 2 }));
    try std.testing.expectEqual(Known{ .int = 0 }, try fold(.mod, .{ .int = std.math.minInt(i128) }, .{ .int = -1 }));
}
