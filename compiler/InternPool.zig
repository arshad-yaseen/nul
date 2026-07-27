//! Interned strings and types, one table per compilation.
//!
//! Everything is addressed by a `u32` index into a struct-of-arrays, the same shape
//! `Ast` uses, so the tables can grow without invalidating anything already handed
//! out. Nothing here stores a pointer.
//!
//! Types are interned so that identity is an integer compare. Structs are the one
//! exception to structural interning: each `struct { ... }` in the source is its own
//! type, so the syntax node is the whole key. That is also what lets a struct name
//! itself, since the type exists before its fields are filled in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");

const InternPool = @This();

/// Every distinct string, concatenated. `string_starts` delimits them.
string_bytes: std.ArrayList(u8),
/// `string_starts[i]..string_starts[i + 1]` is string `i`, so this holds one more
/// entry than there are strings.
string_starts: std.ArrayList(u32),
/// Deduplicates strings. Entry `i` is string `i`, which is why the key is `void`.
string_map: std.AutoArrayHashMapUnmanaged(void, void),

items: std.MultiArrayList(Item),
/// Payloads too wide for `Item.data`.
extra: std.ArrayList(u32),
/// Deduplicates `items`. Entry `i` is item `i`.
map: std.AutoArrayHashMapUnmanaged(void, void),

// Storage

const Item = struct {
    tag: Tag,
    /// Reinterpreted by `tag`: a `Simple`, an `Index`, a small integer, or an offset
    /// into `extra`.
    data: u32,
};

const Tag = enum(u8) {
    /// `data` is a `Simple`.
    simple,
    /// `data` is the pointee `Index`. Mutability is the tag, not a stored bit.
    type_pointer,
    type_pointer_var,
    /// `data` is an offset into `extra`, laid out as `Struct` then its fields.
    type_struct,
    /// `data` is a `String`.
    value_str,
    /// `data` is the value itself.
    int_small,
    /// `data` is an offset into `extra` holding an `i64`, low word first.
    int_i64,
};

comptime {
    assert(@sizeOf(Tag) == 1);
    assert(@sizeOf(Field) == 8); // `structFields` casts `extra` straight to these
}

/// The types and values that need no payload, in the order `Index` reserves them.
pub const Simple = enum(u32) {
    type,
    void,
    noreturn,
    bool,
    i64,
    str,
    arena,
    comptime_int,
    void_value,
    true_value,
    false_value,
};

pub const Index = enum(u32) {
    type_type,
    type_void,
    type_noreturn,
    type_bool,
    type_i64,
    type_str,
    type_arena,
    type_comptime_int,
    value_void,
    value_true,
    value_false,
    _,

    /// The reserved indices above, which `init` seeds in this order. `_` is a
    /// non-exhaustive marker rather than a field, so it is not counted here.
    pub const static_count = @typeInfo(Index).@"enum".fields.len;

    pub fn toOptional(i: Index) OptionalIndex {
        return @enumFromInt(@intFromEnum(i));
    }
};

pub const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalIndex) ?Index {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }
};

pub const String = enum(u32) {
    _,

    pub fn toOptional(s: String) OptionalString {
        return @enumFromInt(@intFromEnum(s));
    }
};

pub const OptionalString = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(os: OptionalString) ?String {
        return if (os == .none) null else @enumFromInt(@intFromEnum(os));
    }
};

pub const Field = struct {
    name: String,
    type: Index,
};

// The view

/// An item widened into named fields. Materialized on demand, never stored.
pub const Key = union(enum) {
    simple: Simple,
    pointer: Pointer,
    /// Nominal. The syntax node is the identity, and the fields are filled in after
    /// interning so a struct can name itself.
    struct_type: Ast.Node.Index,
    int: i64,
    str: String,

    pub const Pointer = struct { child: Index, is_mutable: bool };

    fn hash(key: Key) u32 {
        var h: std.hash.Wyhash = .init(@intFromEnum(std.meta.activeTag(key)));
        switch (key) {
            .simple => |s| h.update(std.mem.asBytes(&@intFromEnum(s))),
            .pointer => |p| {
                h.update(std.mem.asBytes(&@intFromEnum(p.child)));
                h.update(std.mem.asBytes(&p.is_mutable));
            },
            .struct_type => |n| h.update(std.mem.asBytes(&@intFromEnum(n))),
            .int => |v| h.update(std.mem.asBytes(&v)),
            .str => |v| h.update(std.mem.asBytes(&@intFromEnum(v))),
        }
        return @truncate(h.final());
    }

    fn eql(a: Key, b: Key) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .simple => |s| s == b.simple,
            .pointer => |p| p.child == b.pointer.child and p.is_mutable == b.pointer.is_mutable,
            .struct_type => |n| n == b.struct_type,
            .int => |v| v == b.int,
            .str => |v| v == b.str,
        };
    }
};

pub fn keyOf(ip: *const InternPool, index: Index) Key {
    const i = @intFromEnum(index);
    const data = ip.items.items(.data)[i];
    return switch (ip.items.items(.tag)[i]) {
        .simple => .{ .simple = @enumFromInt(data) },
        .type_pointer => .{ .pointer = .{ .child = @enumFromInt(data), .is_mutable = false } },
        .type_pointer_var => .{ .pointer = .{ .child = @enumFromInt(data), .is_mutable = true } },
        .type_struct => .{ .struct_type = @enumFromInt(ip.extra.items[data + Struct.node_offset]) },
        .value_str => .{ .str = @enumFromInt(data) },
        .int_small => .{ .int = data },
        .int_i64 => .{ .int = @bitCast(@as(u64, ip.extra.items[data]) |
            (@as(u64, ip.extra.items[data + 1]) << 32)) },
    };
}

/// The header `type_struct` points at, followed by `field_count` `Field`s.
const Struct = struct {
    name: OptionalString,
    node: Ast.Node.Index,
    field_count: u32,

    const len = 3;
    const name_offset = 0;
    const node_offset = 1;
    const count_offset = 2;
};

// Lifecycle

pub fn init(gpa: Allocator) Allocator.Error!InternPool {
    var ip: InternPool = .{
        .string_bytes = .empty,
        .string_starts = .empty,
        .string_map = .empty,
        .items = .empty,
        .extra = .empty,
        .map = .empty,
    };
    errdefer ip.deinit(gpa);

    try ip.string_starts.append(gpa, 0);

    // Exact, so seeding costs one allocation rather than a geometric run of them.
    try ip.items.ensureTotalCapacity(gpa, Index.static_count);
    try ip.map.ensureTotalCapacity(gpa, Index.static_count);

    // Seeded in `Index` order, so the reserved names are correct by construction.
    for (std.enums.values(Simple)) |s| {
        const index = try ip.get(gpa, .{ .simple = s });
        assert(@intFromEnum(index) == @intFromEnum(s));
    }
    assert(ip.items.len == Index.static_count);

    return ip;
}

pub fn deinit(ip: *InternPool, gpa: Allocator) void {
    ip.string_bytes.deinit(gpa);
    ip.string_starts.deinit(gpa);
    ip.string_map.deinit(gpa);
    ip.items.deinit(gpa);
    ip.extra.deinit(gpa);
    ip.map.deinit(gpa);
    ip.* = undefined;
}

// Strings

const StringAdapter = struct {
    ip: *const InternPool,

    pub fn hash(_: StringAdapter, s: []const u8) u32 {
        return @truncate(std.hash.Wyhash.hash(0, s));
    }

    pub fn eql(ctx: StringAdapter, a: []const u8, _: void, b_index: usize) bool {
        return std.mem.eql(u8, a, ctx.ip.stringSlice(@enumFromInt(b_index)));
    }
};

pub fn getString(ip: *InternPool, gpa: Allocator, s: []const u8) Allocator.Error!String {
    // Interning is mostly hits, so look before reserving. The common path is then
    // one hash probe, with no capacity check and no chance of failing at all.
    if (ip.string_map.getIndexAdapted(s, StringAdapter{ .ip = ip })) |i| return @enumFromInt(i);

    try ip.string_bytes.ensureUnusedCapacity(gpa, s.len);
    try ip.string_starts.ensureUnusedCapacity(gpa, 1);

    const gop = try ip.string_map.getOrPutAdapted(gpa, s, StringAdapter{ .ip = ip });
    assert(!gop.found_existing); // just looked, and nothing ran in between

    ip.string_bytes.appendSliceAssumeCapacity(s);
    ip.string_starts.appendAssumeCapacity(@intCast(ip.string_bytes.items.len));
    assert(ip.string_starts.items.len == ip.string_map.count() + 1);
    return @enumFromInt(gop.index);
}

pub fn stringSlice(ip: *const InternPool, s: String) []const u8 {
    const i = @intFromEnum(s);
    return ip.string_bytes.items[ip.string_starts.items[i]..ip.string_starts.items[i + 1]];
}

// Types and values

const KeyAdapter = struct {
    ip: *const InternPool,

    pub fn hash(_: KeyAdapter, key: Key) u32 {
        return key.hash();
    }

    pub fn eql(ctx: KeyAdapter, a: Key, _: void, b_index: usize) bool {
        return a.eql(ctx.ip.keyOf(@enumFromInt(b_index)));
    }
};

/// Interns anything whose payload is known up front. Structs go through
/// `getStructType`, because their fields arrive later.
pub fn get(ip: *InternPool, gpa: Allocator, key: Key) Allocator.Error!Index {
    assert(key != .struct_type);

    // Look before reserving, because a hit is the common case and should not pay a
    // capacity check. On a miss, reserving first is what keeps `map` and `items`
    // from disagreeing if an allocation fails.
    if (ip.map.getIndexAdapted(key, KeyAdapter{ .ip = ip })) |i| return @enumFromInt(i);

    try ip.items.ensureUnusedCapacity(gpa, 1);
    if (key == .int and !fitsSmall(key.int)) try ip.extra.ensureUnusedCapacity(gpa, 2);

    const gop = try ip.map.getOrPutAdapted(gpa, key, KeyAdapter{ .ip = ip });
    assert(!gop.found_existing); // just looked, and nothing ran in between
    assert(gop.index == ip.items.len);

    ip.items.appendAssumeCapacity(switch (key) {
        .simple => |s| .{ .tag = .simple, .data = @intFromEnum(s) },
        .str => |v| .{ .tag = .value_str, .data = @intFromEnum(v) },
        .pointer => |p| .{
            .tag = if (p.is_mutable) .type_pointer_var else .type_pointer,
            .data = @intFromEnum(p.child),
        },
        .int => |v| if (fitsSmall(v)) .{
            .tag = .int_small,
            .data = @intCast(v),
        } else blk: {
            const at: u32 = @intCast(ip.extra.items.len);
            const bits: u64 = @bitCast(v);
            ip.extra.appendAssumeCapacity(@truncate(bits));
            ip.extra.appendAssumeCapacity(@truncate(bits >> 32));
            break :blk .{ .tag = .int_i64, .data = at };
        },
        .struct_type => unreachable,
    });
    return @enumFromInt(gop.index);
}

fn fitsSmall(v: i64) bool {
    return v >= 0 and v <= std.math.maxInt(u32);
}

/// Looks up without interning, for callers that need to know whether a type is new.
pub fn getIfExists(ip: *const InternPool, key: Key) ?Index {
    const i = ip.map.getIndexAdapted(key, KeyAdapter{ .ip = ip }) orelse return null;
    return @enumFromInt(i);
}

/// Interns the struct declared at `node`, reserving room for its fields. Calling
/// twice with the same node yields the same type, fields and all.
pub fn getStructType(
    ip: *InternPool,
    gpa: Allocator,
    node: Ast.Node.Index,
    name: OptionalString,
    field_count: u32,
) Allocator.Error!Index {
    const key: Key = .{ .struct_type = node };
    if (ip.map.getIndexAdapted(key, KeyAdapter{ .ip = ip })) |i| return @enumFromInt(i);

    try ip.items.ensureUnusedCapacity(gpa, 1);
    try ip.extra.ensureUnusedCapacity(gpa, Struct.len + field_count * 2);

    const gop = try ip.map.getOrPutAdapted(gpa, key, KeyAdapter{ .ip = ip });
    assert(!gop.found_existing); // just looked, and nothing ran in between
    assert(gop.index == ip.items.len);

    const at: u32 = @intCast(ip.extra.items.len);
    ip.extra.appendAssumeCapacity(@intFromEnum(name));
    ip.extra.appendAssumeCapacity(@intFromEnum(node));
    ip.extra.appendAssumeCapacity(field_count);
    // Fields land in `setStructField`. Until then they read as unnamed `void`, which
    // keeps every query total while a recursive type is still half built.
    for (0..field_count) |_| {
        ip.extra.appendAssumeCapacity(0);
        ip.extra.appendAssumeCapacity(@intFromEnum(Index.type_void));
    }

    ip.items.appendAssumeCapacity(.{ .tag = .type_struct, .data = at });
    return @enumFromInt(gop.index);
}

pub fn setStructField(ip: *InternPool, index: Index, i: u32, field: Field) void {
    const at = ip.structExtra(index);
    assert(i < ip.extra.items[at + Struct.count_offset]);
    const base = at + Struct.len + i * 2;
    ip.extra.items[base] = @intFromEnum(field.name);
    ip.extra.items[base + 1] = @intFromEnum(field.type);
}

pub fn structFields(ip: *const InternPool, index: Index) []const Field {
    const at = ip.structExtra(index);
    const count = ip.extra.items[at + Struct.count_offset];
    return @ptrCast(ip.extra.items[at + Struct.len ..][0 .. count * 2]);
}

pub fn structName(ip: *const InternPool, index: Index) OptionalString {
    return @enumFromInt(ip.extra.items[ip.structExtra(index) + Struct.name_offset]);
}

pub fn fieldIndex(ip: *const InternPool, index: Index, name: String) ?u32 {
    for (ip.structFields(index), 0..) |f, i| {
        if (f.name == name) return @intCast(i);
    }
    return null;
}

fn structExtra(ip: *const InternPool, index: Index) u32 {
    const i = @intFromEnum(index);
    assert(ip.items.items(.tag)[i] == .type_struct);
    return ip.items.items(.data)[i];
}

// Queries

/// The type of a value. A type is itself a value, and its type is `type`, which is
/// what lets one evaluator serve both type expressions and ordinary constants.
pub fn typeOf(ip: *const InternPool, index: Index) Index {
    const i = @intFromEnum(index);
    return switch (ip.items.items(.tag)[i]) {
        .type_pointer, .type_pointer_var, .type_struct => .type_type,
        .simple => switch (@as(Simple, @enumFromInt(ip.items.items(.data)[i]))) {
            .void_value => .type_void,
            .true_value, .false_value => .type_bool,
            else => .type_type,
        },
        .value_str => .type_str,
        .int_small, .int_i64 => .type_i64,
    };
}

pub fn isType(ip: *const InternPool, index: Index) bool {
    return ip.typeOf(index) == .type_type;
}

pub fn isPointer(ip: *const InternPool, index: Index) bool {
    return switch (ip.items.items(.tag)[@intFromEnum(index)]) {
        .type_pointer, .type_pointer_var => true,
        else => false,
    };
}

/// Whether a value of this type can be copied between arenas. A copy moves the bytes
/// a value owns directly, so anything reaching outside itself cannot be relabelled.
///
/// `Arena` counts as reaching outside: it names a region, and copying one upward
/// would hand longer lived memory a name for something already dead.
///
/// Recomputed per call. Field counts are small and this is asked once per `copy`.
///
/// Assumes no struct contains itself by value, which is a type of infinite size and
/// an error `Sema` does not detect yet. Nothing calls this until the `copy` rule
/// lands, and that check has to land with it.
pub fn isPointerFree(ip: *const InternPool, index: Index) bool {
    const i = @intFromEnum(index);
    return switch (ip.items.items(.tag)[i]) {
        .type_pointer, .type_pointer_var => false,
        .simple => @as(Simple, @enumFromInt(ip.items.items(.data)[i])) != .arena,
        .type_struct => {
            for (ip.structFields(index)) |f| {
                if (!ip.isPointerFree(f.type)) return false;
            }
            return true;
        },
        .int_small, .int_i64, .value_str => true,
    };
}

/// Writes a type the way a programmer wrote it, for diagnostics.
pub fn printType(ip: *const InternPool, index: Index, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const i = @intFromEnum(index);
    switch (ip.items.items(.tag)[i]) {
        .simple => try w.writeAll(switch (@as(Simple, @enumFromInt(ip.items.items(.data)[i]))) {
            .type => "type",
            .void => "void",
            .noreturn => "noreturn",
            .bool => "bool",
            .i64 => "i64",
            .str => "str",
            .arena => "Arena",
            .comptime_int => "comptime_int",
            .void_value, .true_value, .false_value => "value",
        }),
        .type_pointer, .type_pointer_var => |tag| {
            try w.writeAll(if (tag == .type_pointer_var) "*var " else "*");
            try ip.printType(@enumFromInt(ip.items.items(.data)[i]), w);
        },
        .type_struct => if (ip.structName(index).unwrap()) |name|
            try w.writeAll(ip.stringSlice(name))
        else
            try w.writeAll("struct"),
        .int_small, .int_i64 => try w.writeAll("comptime_int"),
        .value_str => try w.writeAll("str"),
    }
}
