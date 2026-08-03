//! One item per type and per constant, so equality is index equality.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Module = @import("Module.zig");

items: std.MultiArrayList(Item),
/// Wide payloads, each a type and its value words.
extra: std.ArrayList(u32),
/// Every interned string, null terminated.
bytes: std.ArrayList(u8),
/// Item lookup, so one (tag, payload) is one index forever.
map: std.HashMapUnmanaged(Index, void, IndexContext, load_percentage),
string_map: std.HashMapUnmanaged(String, void, StringContext, load_percentage),

const load_percentage = std.hash_map.default_max_load_percentage;

const Pool = @This();

/// Interned before any source is read.
const statics = @typeInfo(SimpleType).@"enum".fields.len +
    @typeInfo(SimpleValue).@"enum".fields.len;

/// A type or a constant. `init` interns the named items in this order.
pub const Index = enum(u32) {
    /// A broken type and a broken value, which stays silent.
    poison,
    bool_type,
    i8_type,
    i16_type,
    i32_type,
    i64_type,
    u8_type,
    u16_type,
    u32_type,
    u64_type,
    f32_type,
    f64_type,
    /// What a function with no return type returns.
    void_type,
    /// A number that has not met a type yet.
    untyped_int_type,
    untyped_float_type,
    /// The one universal error set, the type of a caught `|err|`.
    error_type,
    true_value,
    false_value,
    /// `null` before it meets an optional type.
    untyped_null_value,
    _,

    pub fn from(raw: usize) Index {
        assert(raw < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(raw)));
    }

    pub fn int(index: Index) u32 {
        return @intFromEnum(index);
    }
};

/// A struct instantiation. The rows live on `Compilation`.
pub const Instance = enum(u32) {
    _,

    pub fn from(raw: usize) Instance {
        assert(raw < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(raw)));
    }

    pub fn int(index: Instance) u32 {
        return @intFromEnum(index);
    }
};

/// An offset into `bytes`. The text runs to the next zero byte.
pub const String = enum(u32) {
    empty = 0,
    _,

    pub fn from(raw: usize) String {
        assert(raw < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(raw)));
    }

    pub fn int(index: String) u32 {
        return @intFromEnum(index);
    }
};

/// A type with no payload, pinned to the static item it occupies.
pub const SimpleType = enum(u32) {
    poison = @intFromEnum(Index.poison),
    bool = @intFromEnum(Index.bool_type),
    i8 = @intFromEnum(Index.i8_type),
    i16 = @intFromEnum(Index.i16_type),
    i32 = @intFromEnum(Index.i32_type),
    i64 = @intFromEnum(Index.i64_type),
    u8 = @intFromEnum(Index.u8_type),
    u16 = @intFromEnum(Index.u16_type),
    u32 = @intFromEnum(Index.u32_type),
    u64 = @intFromEnum(Index.u64_type),
    f32 = @intFromEnum(Index.f32_type),
    f64 = @intFromEnum(Index.f64_type),
    void = @intFromEnum(Index.void_type),
    untyped_int = @intFromEnum(Index.untyped_int_type),
    untyped_float = @intFromEnum(Index.untyped_float_type),
    @"error" = @intFromEnum(Index.error_type),

    pub fn index(simple: SimpleType) Index {
        return @enumFromInt(@intFromEnum(simple));
    }

    /// Whether source may write this name.
    fn isSpellable(simple: SimpleType) bool {
        return switch (simple) {
            .bool => true,
            .i8, .i16, .i32, .i64 => true,
            .u8, .u16, .u32, .u64 => true,
            .f32, .f64 => true,
            .poison, .void, .untyped_int, .untyped_float, .@"error" => false,
        };
    }
};

/// A value with no payload, pinned the same way.
pub const SimpleValue = enum(u32) {
    true = @intFromEnum(Index.true_value),
    false = @intFromEnum(Index.false_value),
    /// Before it meets an optional type.
    null = @intFromEnum(Index.untyped_null_value),

    pub fn index(simple: SimpleValue) Index {
        return @enumFromInt(@intFromEnum(simple));
    }
};

// the prelude scope

/// The type a name means in every file, read off the static items.
pub fn preludeType(text: []const u8) ?Index {
    return prelude.get(text);
}

/// For a suggestion when a name is missed.
pub const prelude_names = prelude.keys();

const prelude = build: {
    const simples = std.enums.values(SimpleType);
    var entries: [simples.len]struct { []const u8, Index } = undefined;
    var count: usize = 0;
    for (simples) |simple| {
        if (simple.isSpellable() == false) continue;
        entries[count] = .{ @tagName(simple), simple.index() };
        count += 1;
    }
    break :build std.StaticStringMap(Index).initComptime(entries[0..count].*);
};

/// What one item means, spelled like the tag it is stored under.
pub const Key = union(enum) {
    type_simple: SimpleType,
    type_pointer: Pointer,
    type_optional: Index,
    type_error_union: Index,
    /// A nominal struct, whose identity is the instantiation.
    type_struct: Instance,

    value_simple: SimpleValue,
    value_int: Int,
    value_float: Float,
    /// A declared error.
    value_error: Module.Decl.Index,
    /// `null` once it met an optional type, which is the index here.
    value_typed_null: Index,

    pub const Pointer = struct { child: Index, mutable: bool };
    pub const Int = struct { type: Index, value: i128 };
    pub const Float = struct { type: Index, value: f64 };

    fn hash(key: Key) u64 {
        var hasher = std.hash.Wyhash.init(@intFromEnum(std.meta.activeTag(key)));
        switch (key) {
            .type_simple => |simple| hasher.update(std.mem.asBytes(&simple)),
            .value_simple => |simple| hasher.update(std.mem.asBytes(&simple)),
            .type_pointer => |pointer| {
                hasher.update(std.mem.asBytes(&pointer.child));
                hasher.update(std.mem.asBytes(&pointer.mutable));
            },
            .type_optional, .type_error_union, .value_typed_null => |child| {
                hasher.update(std.mem.asBytes(&child));
            },
            .type_struct => |instance| hasher.update(std.mem.asBytes(&instance)),
            .value_int => |it| {
                hasher.update(std.mem.asBytes(&it.type));
                hasher.update(std.mem.asBytes(&it.value));
            },
            .value_float => |it| {
                const bits: u64 = @bitCast(it.value);
                hasher.update(std.mem.asBytes(&it.type));
                hasher.update(std.mem.asBytes(&bits));
            },
            .value_error => |text| hasher.update(std.mem.asBytes(&text)),
        }
        return hasher.final();
    }

    fn eql(key: Key, other: Key) bool {
        if (std.meta.activeTag(key) != std.meta.activeTag(other)) return false;
        return switch (key) {
            .type_simple => |simple| simple == other.type_simple,
            .value_simple => |simple| simple == other.value_simple,
            .type_pointer => |pointer| pointer.child == other.type_pointer.child and
                pointer.mutable == other.type_pointer.mutable,
            .type_optional => |child| child == other.type_optional,
            .type_error_union => |child| child == other.type_error_union,
            .value_typed_null => |child| child == other.value_typed_null,
            .type_struct => |instance| instance == other.type_struct,
            .value_int => |it| it.type == other.value_int.type and it.value == other.value_int.value,
            // by bits, so float equality is never asked
            .value_float => |it| it.type == other.value_float.type and
                @as(u64, @bitCast(it.value)) == @as(u64, @bitCast(other.value_float.value)),
            .value_error => |text| text == other.value_error,
        };
    }
};

const Item = struct {
    tag: Tag,
    data: u32,

    const Tag = enum(u8) {
        type_simple,
        type_pointer,
        type_pointer_var,
        type_optional,
        type_error_union,
        type_struct,
        value_simple,
        /// `data` points at `extra`.
        value_int,
        /// `data` points at `extra`.
        value_float,
        value_error,
        value_typed_null,
    };
};

comptime {
    assert(@sizeOf(Item.Tag) == 1);
}

pub fn init(pool: *Pool, gpa: Allocator) Allocator.Error!void {
    pool.* = .{
        .items = .empty,
        .extra = .empty,
        .bytes = .empty,
        .map = .empty,
        .string_map = .empty,
    };
    errdefer pool.deinit(gpa);

    // a few hundred items per source file
    try pool.items.ensureTotalCapacity(gpa, 256);
    try pool.bytes.ensureTotalCapacity(gpa, 1024);

    // offset zero is the empty string, so `String.empty` needs no lookup
    pool.bytes.appendAssumeCapacity(0);

    for (std.enums.values(SimpleType)) |simple| {
        const index = try pool.intern(gpa, .{ .type_simple = simple });
        assert(index == simple.index());
    }
    for (std.enums.values(SimpleValue)) |simple| {
        const index = try pool.intern(gpa, .{ .value_simple = simple });
        assert(index == simple.index());
    }
    assert(pool.items.len == statics);
}

pub fn deinit(pool: *Pool, gpa: Allocator) void {
    pool.items.deinit(gpa);
    pool.extra.deinit(gpa);
    pool.bytes.deinit(gpa);
    pool.map.deinit(gpa);
    pool.string_map.deinit(gpa);
    pool.* = undefined;
}

// interning

pub fn intern(pool: *Pool, gpa: Allocator, key: Key) Allocator.Error!Index {
    const gop = try pool.map.getOrPutContextAdapted(
        gpa,
        key,
        KeyAdapter{ .pool = pool },
        IndexContext{ .pool = pool },
    );
    if (gop.found_existing) return gop.key_ptr.*;

    if (pool.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const index: Index = .from(pool.items.len);

    const item: Item = switch (key) {
        .type_simple => |simple| .{ .tag = .type_simple, .data = @intFromEnum(simple) },
        .value_simple => |simple| .{ .tag = .value_simple, .data = @intFromEnum(simple) },
        .type_pointer => |pointer| .{
            .tag = if (pointer.mutable) .type_pointer_var else .type_pointer,
            .data = pointer.child.int(),
        },
        .type_optional => |child| .{ .tag = .type_optional, .data = child.int() },
        .type_error_union => |child| .{ .tag = .type_error_union, .data = child.int() },
        .type_struct => |instance| .{ .tag = .type_struct, .data = instance.int() },
        .value_int => |it| .{
            .tag = .value_int,
            .data = try pool.addExtra(gpa, it.type, &wordsOf(it.value)),
        },
        .value_float => |it| .{
            .tag = .value_float,
            .data = try pool.addExtra(gpa, it.type, &wordsOf(@as(u64, @bitCast(it.value)))),
        },
        .value_error => |declared| .{ .tag = .value_error, .data = declared.int() },
        .value_typed_null => |child| .{ .tag = .value_typed_null, .data = child.int() },
    };
    try pool.items.append(gpa, item);
    gop.key_ptr.* = index;

    assert(pool.items.len == index.int() + 1);
    assert(key.eql(pool.keyOf(index)));
    return index;
}

pub fn keyOf(pool: *const Pool, index: Index) Key {
    assert(index.int() < pool.items.len);

    const data = pool.items.items(.data)[index.int()];
    return switch (pool.items.items(.tag)[index.int()]) {
        .type_simple => .{ .type_simple = @enumFromInt(data) },
        .value_simple => .{ .value_simple = @enumFromInt(data) },
        .type_pointer => .{ .type_pointer = .{ .child = @enumFromInt(data), .mutable = false } },
        .type_pointer_var => .{ .type_pointer = .{ .child = @enumFromInt(data), .mutable = true } },
        .type_optional => .{ .type_optional = @enumFromInt(data) },
        .type_error_union => .{ .type_error_union = @enumFromInt(data) },
        .type_struct => .{ .type_struct = @enumFromInt(data) },
        .value_int => .{ .value_int = .{
            .type = @enumFromInt(pool.extra.items[data]),
            .value = @bitCast(pool.extraWords(data + 1, 4).*),
        } },
        .value_float => .{ .value_float = .{
            .type = @enumFromInt(pool.extra.items[data]),
            .value = @bitCast(@as(u64, @bitCast(pool.extraWords(data + 1, 2).*))),
        } },
        .value_error => .{ .value_error = @enumFromInt(data) },
        .value_typed_null => .{ .value_typed_null = @enumFromInt(data) },
    };
}

pub fn string(pool: *Pool, gpa: Allocator, text: []const u8) Allocator.Error!String {
    assert(std.mem.indexOfScalar(u8, text, 0) == null);

    const gop = try pool.string_map.getOrPutContextAdapted(
        gpa,
        text,
        StringAdapter{ .bytes = &pool.bytes },
        StringContext{ .bytes = &pool.bytes },
    );
    if (gop.found_existing) return gop.key_ptr.*;

    if (pool.bytes.items.len + text.len + 1 > std.math.maxInt(u32)) return error.OutOfMemory;
    const offset: String = .from(pool.bytes.items.len);

    try pool.bytes.ensureUnusedCapacity(gpa, text.len + 1);
    pool.bytes.appendSliceAssumeCapacity(text);
    pool.bytes.appendAssumeCapacity(0);
    gop.key_ptr.* = offset;

    assert(std.mem.eql(u8, pool.stringText(offset), text));
    return offset;
}

pub fn stringText(pool: *const Pool, index: String) [:0]const u8 {
    assert(index.int() < pool.bytes.items.len);
    const base = pool.bytes.items[index.int()..];
    // interning terminates every string, so the zero byte is always found
    const length = std.mem.indexOfScalar(u8, base, 0).?;
    return base[0..length :0];
}

// questions every stage asks

/// Only a value has one. `poison` is both, and answers with itself.
pub fn typeOfValue(pool: *const Pool, value: Index) Index {
    return switch (pool.keyOf(value)) {
        .value_simple => |simple| switch (simple) {
            .true, .false => .bool_type,
            // untyped `null` is spelled by itself, having met no optional yet
            .null => .untyped_null_value,
        },
        .value_int => |it| it.type,
        .value_float => |it| it.type,
        .value_error => .error_type,
        .value_typed_null => |optional| optional,
        .type_simple => |simple| simple: {
            assert(simple == .poison);
            break :simple .poison;
        },
        .type_pointer, .type_optional, .type_error_union, .type_struct => unreachable,
    };
}

pub fn isType(pool: *const Pool, index: Index) bool {
    return switch (pool.keyOf(index)) {
        .type_simple, .type_pointer, .type_optional, .type_error_union, .type_struct => true,
        .value_simple, .value_int, .value_float, .value_error, .value_typed_null => false,
    };
}

pub fn isInteger(index: Index) bool {
    return switch (index) {
        .i8_type, .i16_type, .i32_type, .i64_type => true,
        .u8_type, .u16_type, .u32_type, .u64_type => true,
        .untyped_int_type => true,
        else => false,
    };
}

pub fn isFloat(index: Index) bool {
    return switch (index) {
        .f32_type, .f64_type, .untyped_float_type => true,
        else => false,
    };
}

pub fn isNumeric(index: Index) bool {
    if (isInteger(index)) return true;
    return isFloat(index);
}

pub fn fitsInt(value: i128, type_index: Index) bool {
    assert(isInteger(type_index) or isFloat(type_index));
    return switch (type_index) {
        .i8_type => value >= std.math.minInt(i8) and value <= std.math.maxInt(i8),
        .i16_type => value >= std.math.minInt(i16) and value <= std.math.maxInt(i16),
        .i32_type => value >= std.math.minInt(i32) and value <= std.math.maxInt(i32),
        .i64_type => value >= std.math.minInt(i64) and value <= std.math.maxInt(i64),
        .u8_type => value >= 0 and value <= std.math.maxInt(u8),
        .u16_type => value >= 0 and value <= std.math.maxInt(u16),
        .u32_type => value >= 0 and value <= std.math.maxInt(u32),
        .u64_type => value >= 0 and value <= std.math.maxInt(u64),
        .untyped_int_type => true,
        // every i128 is below the smallest float infinity
        .f32_type, .f64_type, .untyped_float_type => true,
        else => unreachable,
    };
}

// the constant-folding core

/// Everything except `value` is a mistake, reported at the operator.
pub const Fold = union(enum) {
    value: Index,
    /// Past the 128 bits constants fold in.
    overflow,
    division_by_zero,
    /// Refused by the type both operands carry.
    does_not_fit: struct { value: i128, type: Index },
    mismatch: struct { left: Index, right: Index },
    bad_operand: Index,
};

pub fn fold(
    pool: *Pool,
    gpa: Allocator,
    op: AST.BinaryOp,
    lhs: Index,
    rhs: Index,
) Allocator.Error!Fold {
    if (lhs == .poison) return .{ .value = .poison };
    if (rhs == .poison) return .{ .value = .poison };

    const left = pool.keyOf(lhs);
    const right = pool.keyOf(rhs);

    switch (op) {
        .bool_and, .bool_or => {
            const a = boolOf(left) orelse return .{ .bad_operand = pool.typeOfValue(lhs) };
            const b = boolOf(right) orelse return .{ .bad_operand = pool.typeOfValue(rhs) };
            const result = if (op == .bool_and) a and b else a or b;
            return .{ .value = if (result) .true_value else .false_value };
        },
        else => {},
    }

    if (left == .value_error or right == .value_error) return pool.foldError(op, lhs, rhs);

    const a = numberOf(left) orelse return .{ .bad_operand = pool.typeOfValue(lhs) };
    const b = numberOf(right) orelse return .{ .bad_operand = pool.typeOfValue(rhs) };

    const result_type = sharedType(a.type, b.type) orelse {
        return .{ .mismatch = .{ .left = a.type, .right = b.type } };
    };

    if (isFloat(result_type)) {
        return pool.foldFloat(gpa, op, a.toFloat(), b.toFloat(), result_type);
    }
    return pool.foldInt(gpa, op, a.int, b.int, result_type);
}

pub fn foldNegate(pool: *Pool, gpa: Allocator, operand: Index) Allocator.Error!Fold {
    if (operand == .poison) return .{ .value = .poison };

    const number = numberOf(pool.keyOf(operand)) orelse {
        return .{ .bad_operand = pool.typeOfValue(operand) };
    };
    if (isFloat(number.type)) {
        return pool.internFloat(gpa, -number.toFloat(), number.type);
    }
    const negated = std.math.negate(number.int) catch return .overflow;
    return pool.internInt(gpa, negated, number.type);
}

pub fn foldNot(pool: *const Pool, operand: Index) Fold {
    if (operand == .poison) return .{ .value = .poison };

    const value = boolOf(pool.keyOf(operand)) orelse {
        return .{ .bad_operand = pool.typeOfValue(operand) };
    };
    return .{ .value = if (value) .false_value else .true_value };
}

pub const Fit = union(enum) {
    value: Index,
    /// Right in kind, wrong in size.
    does_not_fit,
    wrong_kind,
};

/// By value rather than by type. Wrapping stays with the caller, because it
/// produces instructions.
pub fn fit(pool: *Pool, gpa: Allocator, value: Index, type_index: Index) Allocator.Error!Fit {
    if (value == .poison) return .{ .value = .poison };
    if (type_index == .poison) return .{ .value = .poison };
    assert(pool.isType(type_index));

    switch (pool.keyOf(value)) {
        .value_int => |it| {
            if (isInteger(type_index)) {
                if (fitsInt(it.value, type_index) == false) return .does_not_fit;
                return .{ .value = try pool.internWith(gpa, it.value, type_index) };
            }
            if (isFloat(type_index)) {
                return .{ .value = try pool.internWith(gpa, it.value, type_index) };
            }
            return .wrong_kind;
        },
        .value_float => |it| {
            if (isFloat(type_index)) {
                const wide = it.value;
                const narrowed: f64 = if (type_index == .f32_type)
                    @floatCast(@as(f32, @floatCast(wide)))
                else
                    wide;
                if (std.math.isInf(narrowed) and std.math.isInf(wide) == false) {
                    return .does_not_fit;
                }
                return .{ .value = try pool.intern(gpa, .{
                    .value_float = .{ .type = type_index, .value = narrowed },
                }) };
            }
            if (isInteger(type_index)) {
                // only a whole number can stop being a float
                const truncated = @trunc(it.value);
                if (truncated != it.value) return .does_not_fit;
                if (it.value < -0x1p127 or it.value >= 0x1p127) return .does_not_fit;
                const as_int: i128 = @intFromFloat(truncated);
                if (fitsInt(as_int, type_index) == false) return .does_not_fit;
                return .{ .value = try pool.internWith(gpa, as_int, type_index) };
            }
            return .wrong_kind;
        },
        .value_simple => |simple| switch (simple) {
            .true, .false => {
                return if (type_index == .bool_type) .{ .value = value } else .wrong_kind;
            },
            .null => switch (pool.keyOf(type_index)) {
                .type_optional => return .{
                    .value = try pool.intern(gpa, .{ .value_typed_null = type_index }),
                },
                else => return .wrong_kind,
            },
        },
        .value_typed_null => |own| {
            if (own == type_index) return .{ .value = value };
            return switch (pool.keyOf(type_index)) {
                .type_optional => .{ .value = try pool.intern(gpa, .{ .value_typed_null = type_index }) },
                else => .wrong_kind,
            };
        },
        .value_error => {
            return if (type_index == .error_type) .{ .value = value } else .wrong_kind;
        },
        .type_simple, .type_pointer, .type_optional, .type_error_union, .type_struct => unreachable,
    }
}

// the arms of the core

/// Widened, so the fold has one integer and one float shape.
const Number = struct {
    type: Index,
    int: i128,
    float: f64,

    fn toFloat(number: Number) f64 {
        if (isFloat(number.type)) return number.float;
        return @floatFromInt(number.int);
    }
};

fn numberOf(key: Key) ?Number {
    return switch (key) {
        .value_int => |it| .{ .type = it.type, .int = it.value, .float = 0 },
        .value_float => |it| .{ .type = it.type, .int = 0, .float = it.value },
        else => null,
    };
}

fn boolOf(key: Key) ?bool {
    return switch (key) {
        .value_simple => |simple| switch (simple) {
            .true => true,
            .false => false,
            .null => null,
        },
        else => null,
    };
}

/// The type two operands share, or null. An untyped operand takes the other.
fn sharedType(left: Index, right: Index) ?Index {
    if (left == right) return left;
    if (left == .untyped_int_type) return right;
    if (right == .untyped_int_type) return left;
    if (left == .untyped_float_type) return if (isFloat(right)) right else null;
    if (right == .untyped_float_type) return if (isFloat(left)) left else null;
    return null;
}

fn foldInt(
    pool: *Pool,
    gpa: Allocator,
    op: AST.BinaryOp,
    a: i128,
    b: i128,
    result_type: Index,
) Allocator.Error!Fold {
    assert(isInteger(result_type));
    switch (op) {
        .add, .sub, .mul => {
            const wide = switch (op) {
                .add => std.math.add(i128, a, b),
                .sub => std.math.sub(i128, a, b),
                .mul => std.math.mul(i128, a, b),
                else => unreachable,
            } catch return .overflow;
            return pool.internInt(gpa, wide, result_type);
        },
        .div => {
            if (b == 0) return .division_by_zero;
            const wide = std.math.divTrunc(i128, a, b) catch return .overflow;
            return pool.internInt(gpa, wide, result_type);
        },
        .mod => {
            if (b == 0) return .division_by_zero;
            // @rem overflows only for minInt / -1
            const wide = if (b == -1) 0 else @rem(a, b);
            return pool.internInt(gpa, wide, result_type);
        },
        .equal => return boolFold(a == b),
        .not_equal => return boolFold(a != b),
        .less_than => return boolFold(a < b),
        .less_or_equal => return boolFold(a <= b),
        .greater_than => return boolFold(a > b),
        .greater_or_equal => return boolFold(a >= b),
        .bool_and, .bool_or => unreachable,
    }
}

fn foldFloat(
    pool: *Pool,
    gpa: Allocator,
    op: AST.BinaryOp,
    a: f64,
    b: f64,
    result_type: Index,
) Allocator.Error!Fold {
    assert(isFloat(result_type));
    switch (op) {
        .add => return pool.internFloat(gpa, a + b, result_type),
        .sub => return pool.internFloat(gpa, a - b, result_type),
        .mul => return pool.internFloat(gpa, a * b, result_type),
        .div => {
            if (b == 0) return .division_by_zero;
            return pool.internFloat(gpa, a / b, result_type);
        },
        .mod => return .{ .bad_operand = result_type },
        .equal => return boolFold(a == b),
        .not_equal => return boolFold(a != b),
        .less_than => return boolFold(a < b),
        .less_or_equal => return boolFold(a <= b),
        .greater_than => return boolFold(a > b),
        .greater_or_equal => return boolFold(a >= b),
        .bool_and, .bool_or => unreachable,
    }
}

/// An error compares with `==` and `!=`, and nothing else.
fn foldError(pool: *const Pool, op: AST.BinaryOp, lhs: Index, rhs: Index) Fold {
    const left = pool.keyOf(lhs);
    const right = pool.keyOf(rhs);
    if (left != .value_error or right != .value_error) {
        return .{ .mismatch = .{
            .left = pool.typeOfValue(lhs),
            .right = pool.typeOfValue(rhs),
        } };
    }
    return switch (op) {
        .equal => boolFold(left.value_error == right.value_error),
        .not_equal => boolFold(left.value_error != right.value_error),
        else => .{ .bad_operand = .error_type },
    };
}

fn boolFold(value: bool) Fold {
    return .{ .value = if (value) Index.true_value else Index.false_value };
}

/// Where overflow in a sized type is caught.
fn internInt(
    pool: *Pool,
    gpa: Allocator,
    value: i128,
    type_index: Index,
) Allocator.Error!Fold {
    assert(isInteger(type_index));
    if (fitsInt(value, type_index) == false) {
        return .{ .does_not_fit = .{ .value = value, .type = type_index } };
    }
    return .{ .value = try pool.intern(gpa, .{
        .value_int = .{ .type = type_index, .value = value },
    }) };
}

fn internFloat(pool: *Pool, gpa: Allocator, value: f64, type_index: Index) Allocator.Error!Fold {
    assert(isFloat(type_index));
    return .{ .value = try pool.intern(gpa, .{
        .value_float = .{ .type = type_index, .value = value },
    }) };
}

/// Into a type already checked to hold the value.
fn internWith(pool: *Pool, gpa: Allocator, value: i128, type_index: Index) Allocator.Error!Index {
    if (isFloat(type_index)) {
        const wide: f64 = @floatFromInt(value);
        const narrowed: f64 = if (type_index == .f32_type)
            @floatCast(@as(f32, @floatCast(wide)))
        else
            wide;
        return pool.intern(gpa, .{ .value_float = .{ .type = type_index, .value = narrowed } });
    }
    assert(fitsInt(value, type_index));
    return pool.intern(gpa, .{ .value_int = .{ .type = type_index, .value = value } });
}

// storage helpers

fn addExtra(
    pool: *Pool,
    gpa: Allocator,
    type_index: Index,
    words: []const u32,
) Allocator.Error!u32 {
    assert(words.len > 0);
    if (pool.extra.items.len + words.len + 1 > std.math.maxInt(u32)) return error.OutOfMemory;

    const start: u32 = @intCast(pool.extra.items.len);
    try pool.extra.ensureUnusedCapacity(gpa, words.len + 1);
    pool.extra.appendAssumeCapacity(type_index.int());
    pool.extra.appendSliceAssumeCapacity(words);

    assert(pool.extra.items.len == start + words.len + 1);
    return start;
}

fn extraWords(pool: *const Pool, start: u32, comptime count: u32) *const [count]u32 {
    assert(start + count <= pool.extra.items.len);
    return pool.extra.items[start..][0..count];
}

fn wordsOf(value: anytype) [@divExact(@bitSizeOf(@TypeOf(value)), 32)]u32 {
    return @bitCast(value);
}

const KeyAdapter = struct {
    pool: *const Pool,

    pub fn hash(_: KeyAdapter, key: Key) u64 {
        return key.hash();
    }

    pub fn eql(adapter: KeyAdapter, key: Key, index: Index) bool {
        return key.eql(adapter.pool.keyOf(index));
    }
};

const IndexContext = struct {
    pool: *const Pool,

    pub fn hash(context: IndexContext, index: Index) u64 {
        return context.pool.keyOf(index).hash();
    }

    pub fn eql(_: IndexContext, a: Index, b: Index) bool {
        return a == b;
    }
};

const StringAdapter = struct {
    bytes: *const std.ArrayList(u8),

    pub fn hash(_: StringAdapter, text: []const u8) u64 {
        return std.hash_map.hashString(text);
    }

    pub fn eql(adapter: StringAdapter, text: []const u8, index: String) bool {
        return std.mem.eql(u8, text, std.mem.sliceTo(adapter.bytes.items[index.int()..], 0));
    }
};

const StringContext = struct {
    bytes: *const std.ArrayList(u8),

    pub fn hash(context: StringContext, index: String) u64 {
        return std.hash_map.hashString(std.mem.sliceTo(context.bytes.items[index.int()..], 0));
    }

    pub fn eql(_: StringContext, a: String, b: String) bool {
        return a == b;
    }
};

const testing = std.testing;

test "one value is one item, and the statics sit where their names say" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator);
    defer pool.deinit(testing.allocator);

    const five = try pool.intern(testing.allocator, .{
        .value_int = .{ .type = .untyped_int_type, .value = 5 },
    });
    const again = try pool.intern(testing.allocator, .{
        .value_int = .{ .type = .untyped_int_type, .value = 5 },
    });
    try testing.expectEqual(five, again);

    const typed = try pool.intern(testing.allocator, .{
        .value_int = .{ .type = .u8_type, .value = 5 },
    });
    try testing.expect(five != typed);

    try testing.expectEqual(Index.bool_type, try pool.intern(testing.allocator, .{
        .type_simple = .bool,
    }));
    try testing.expectEqual(Index.true_value, try pool.intern(testing.allocator, .{
        .value_simple = .true,
    }));
}

test "every prelude name is its own static item, and nothing else has one" {
    try testing.expectEqual(Index.bool_type, preludeType("bool"));
    try testing.expectEqual(Index.i8_type, preludeType("i8"));
    try testing.expectEqual(Index.u64_type, preludeType("u64"));
    try testing.expectEqual(Index.f64_type, preludeType("f64"));

    try testing.expectEqual(null, preludeType("nothing"));
    try testing.expectEqual(null, preludeType("error"));
    try testing.expectEqual(null, preludeType("true"));
    try testing.expectEqual(null, preludeType("poison"));
    try testing.expectEqual(null, preludeType("int"));

    try testing.expectEqual(11, prelude_names.len);
    for (prelude_names) |name| try testing.expect(preludeType(name) != null);
}

test "folding is 128 bits wide and reports the edge" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator);
    defer pool.deinit(testing.allocator);
    const gpa = testing.allocator;

    const a = try pool.intern(gpa, .{ .value_int = .{ .type = .untyped_int_type, .value = 255 } });
    const b = try pool.intern(gpa, .{ .value_int = .{ .type = .untyped_int_type, .value = 1 } });

    const sum = try pool.fold(gpa, .add, a, b);
    try testing.expectEqual(@as(i128, 256), pool.keyOf(sum.value).value_int.value);

    const zero = try pool.intern(gpa, .{ .value_int = .{ .type = .untyped_int_type, .value = 0 } });
    try testing.expectEqual(Fold.division_by_zero, try pool.fold(gpa, .div, a, zero));

    const huge = try pool.intern(gpa, .{
        .value_int = .{ .type = .untyped_int_type, .value = std.math.maxInt(i128) },
    });
    try testing.expectEqual(Fold.overflow, try pool.fold(gpa, .add, huge, b));
}

test "a typed operand types the fold, and the type refuses what it cannot hold" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator);
    defer pool.deinit(testing.allocator);
    const gpa = testing.allocator;

    const typed = try pool.intern(gpa, .{ .value_int = .{ .type = .u8_type, .value = 200 } });
    const untyped = try pool.intern(gpa, .{ .value_int = .{ .type = .untyped_int_type, .value = 100 } });

    const folded = try pool.fold(gpa, .add, typed, untyped);
    try testing.expectEqual(@as(i128, 300), folded.does_not_fit.value);
    try testing.expectEqual(Index.u8_type, folded.does_not_fit.type);

    const other = try pool.intern(gpa, .{ .value_int = .{ .type = .i64_type, .value = 1 } });
    const mixed = try pool.fold(gpa, .add, typed, other);
    try testing.expectEqual(Index.u8_type, mixed.mismatch.left);
    try testing.expectEqual(Index.i64_type, mixed.mismatch.right);
}

test "a constant meets a type by value, not by type" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator);
    defer pool.deinit(testing.allocator);
    const gpa = testing.allocator;

    const wide = try pool.intern(gpa, .{ .value_int = .{ .type = .i64_type, .value = 100 } });
    const narrowed = try pool.fit(gpa, wide, .u8_type);
    try testing.expectEqual(Index.u8_type, pool.keyOf(narrowed.value).value_int.type);

    const big = try pool.intern(gpa, .{ .value_int = .{ .type = .untyped_int_type, .value = 256 } });
    try testing.expectEqual(Fit.does_not_fit, try pool.fit(gpa, big, .u8_type));

    const optional = try pool.intern(gpa, .{ .type_optional = .i64_type });
    const met = try pool.fit(gpa, .untyped_null_value, optional);
    try testing.expectEqual(optional, pool.keyOf(met.value).value_typed_null);
}
