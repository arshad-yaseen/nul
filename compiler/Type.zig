//! The type system in one place, holding storage, identity, and relations. Every
//! distinct type is interned once, so "the same type" is one integer compare.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const Value = @import("Value.zig");

const Type = @This();

entries: std.MultiArrayList(Entry),
/// Struct bodies and signatures.
extra: std.ArrayList(u32),
/// NUL terminated; `String` is a position here.
strings: std.ArrayList(u8),
/// In lockstep with `entries`, so map position N describes type N.
dedup: std.AutoArrayHashMapUnmanaged(void, void),
next_nominal_id: u32,

/// The types that exist before any source is read, in seeding order. Everything up
/// to `poisoned` is spelled the way Nul spells it.
pub const Index = enum(u32) {
    void,
    never,
    bool,
    type,
    comptime_int,
    comptime_float,
    str,
    Arena,
    f32,
    f64,
    i8,
    i16,
    i32,
    i64,
    isize,
    u8,
    u16,
    u32,
    u64,
    usize,
    /// What analysis yields once it has reported why it has no answer. Not `never`,
    /// which is a type a program can mean.
    poisoned,
    _,
};

/// Not deduplicated, so a repeated name costs its bytes twice.
pub const String = enum(u32) { empty = 0, _ };

pub const Func = struct { params: []const Index, return_type: Index };

// Builtins

pub fn builtinName(index: Index) ?[]const u8 {
    return std.enums.tagName(Index, index);
}

/// Every spelling that names a builtin: everything before `poisoned`, plus aliases.
const builtin_map = std.StaticStringMap(Index).initComptime(blk: {
    const fields = @typeInfo(Index).@"enum".fields;
    const count = @intFromEnum(Index.poisoned);
    var kvs: [count + 2]struct { []const u8, Index } = undefined;
    for (kvs[0..count], fields[0..count]) |*kv, field| {
        kv.* = .{ field.name, @enumFromInt(field.value) };
    }
    kvs[count] = .{ "int", .i64 };
    kvs[count + 1] = .{ "uint", .u64 };
    break :blk kvs;
});

pub fn builtinNamed(name: []const u8) ?Index {
    return builtin_map.get(name);
}

pub fn init(gpa: Allocator) Allocator.Error!Type {
    var types: Type = .{
        .entries = .empty,
        .extra = .empty,
        .strings = .empty,
        .dedup = .empty,
        .next_nominal_id = 0,
    };
    errdefer types.deinit(gpa);

    try types.strings.append(gpa, 0); // so `String.empty` reads back empty

    inline for (@typeInfo(Index).@"enum".fields) |field| {
        const expected: Index = @enumFromInt(field.value);
        const actual = try types.intern(gpa, .{ .builtin = expected });
        assert(actual == expected);
    }
    return types;
}

pub fn deinit(types: *Type, gpa: Allocator) void {
    types.entries.deinit(gpa);
    types.extra.deinit(gpa);
    types.strings.deinit(gpa);
    types.dedup.deinit(gpa);
    types.* = undefined;
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

// Relations

/// Kinds not agreeing is a mistake about types; a value not fitting is about one value.
pub const Refusal = error{ WrongType, OutOfRange };

/// Whether `value` reaches `destination` without changing meaning: its type has to
/// agree in kind, and what is known of it has to fit.
pub fn coerce(types: *const Type, value: Value, destination: Index) Refusal!void {
    const source = value.ty;
    if (source == destination) return;
    if (source == .never) return;

    // A known integer coerces wherever it fits, whatever width it started at.
    if ((value.known == .int and isInteger(source)) or source == .comptime_int) {
        if (isInteger(destination) or isFloat(destination)) return knownFits(value.known, destination);
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

    switch (types.keyOf(source)) {
        .pointer => |from| switch (types.keyOf(destination)) {
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

/// `usize` and `isize` have no range yet, but no unsigned type holds anything negative.
fn knownFits(known: Value.Known, destination: Index) Refusal!void {
    if (known != .int) return;
    if (intRange(destination)) |range| {
        if (known.int < range.min or known.int > range.max) return error.OutOfRange;
    } else if (isUnsignedInt(destination) and known.int < 0) {
        return error.OutOfRange;
    }
}

/// The type two operands settle on, or null when neither reaches the other. Whether
/// each side fits the peer is its own check.
pub fn peer(types: *const Type, a: Index, b: Index) ?Index {
    if (a == .poisoned or b == .poisoned) return .poisoned;
    if (types.coerce(.{ .ty = a }, b)) |_| return b else |_| {}
    if (types.coerce(.{ .ty = b }, a)) |_| return a else |_| {}
    return null;
}

pub fn canEqual(types: *const Type, ty: Index) bool {
    return isNumber(ty) or ty == .bool or types.keyOf(ty) == .pointer;
}

// Queries

pub fn pointeeOf(types: *const Type, ty: Index) ?Index {
    return switch (types.keyOf(ty)) {
        .pointer => |pointer| pointer.pointee,
        else => null,
    };
}

pub fn funcOf(types: *const Type, ty: Index) ?Func {
    return switch (types.keyOf(ty)) {
        .func => |func| func,
        else => null,
    };
}

pub fn isStruct(types: *const Type, ty: Index) bool {
    return types.keyOf(ty) == .struct_type;
}

/// Whether a value can contain an access path to arena memory. `Arena.copy` requires
/// it, since copying a pointer relabels its region without moving what it points at.
pub fn isFlat(types: *const Type, index: Index) bool {
    assert(types.isDefined(index));
    return types.entries.items(.is_flat)[@intFromEnum(index)];
}

/// Whether `Arena.copy` can duplicate everything the value owns: a flat type, or
/// `str`, whose characters it copies.
pub fn isCopyable(types: *const Type, ty: Index) bool {
    return ty == .str or types.isFlat(ty);
}

/// False only between `declareStruct` and `defineStruct`.
pub fn isDefined(types: *const Type, index: Index) bool {
    return switch (types.entries.items(.data)[@intFromEnum(index)]) {
        .struct_type => |at| types.extraData(StructRecord, at).fields_start !=
            StructRecord.body_undefined,
        else => true,
    };
}

// Construction

pub fn pointerType(
    types: *Type,
    gpa: Allocator,
    pointee: Index,
    is_mutable: bool,
) Allocator.Error!Index {
    return types.intern(gpa, .{ .pointer = .{ .pointee = pointee, .is_mutable = is_mutable } });
}

pub fn funcType(
    types: *Type,
    gpa: Allocator,
    params: []const Index,
    return_type: Index,
) Allocator.Error!Index {
    return types.intern(gpa, .{ .func = .{ .params = params, .return_type = return_type } });
}

/// Mints the index before the body is known, so `*Node` interns while `Node`'s fields
/// still resolve. Pair with `defineStruct`, which is also where flatness is decided.
pub fn declareStruct(types: *Type, gpa: Allocator, name: String) Allocator.Error!Index {
    const id: NominalId = @enumFromInt(types.next_nominal_id);
    types.next_nominal_id += 1;
    const index = try types.intern(gpa, .{ .struct_type = id });

    var record = types.extraData(StructRecord, types.structPayload(index));
    record.name = name;
    types.setExtra(types.structPayload(index), record);
    return index;
}

pub fn defineStruct(
    types: *Type,
    gpa: Allocator,
    index: Index,
    field_names: []const String,
    field_types: []const Index,
) Allocator.Error!void {
    assert(field_names.len == field_types.len);
    assert(!types.isDefined(index));

    const fields_at: u32 = @intCast(types.extra.items.len);
    try types.extra.appendSlice(gpa, @ptrCast(field_names));
    try types.extra.appendSlice(gpa, @ptrCast(field_types));

    const at = types.structPayload(index);
    var record = types.extraData(StructRecord, at);
    record.field_count = @intCast(field_names.len);
    record.fields_start = fields_at;
    types.setExtra(at, record);

    var flat = true;
    for (field_types) |field_type| flat = flat and types.isFlat(field_type);
    types.entries.items(.is_flat)[@intFromEnum(index)] = flat;
}

// Struct bodies

pub fn structName(types: *const Type, index: Index) String {
    return types.extraData(StructRecord, types.structPayload(index)).name;
}

pub fn fieldNames(types: *const Type, index: Index) []const String {
    const record = types.extraData(StructRecord, types.structPayload(index));
    return @ptrCast(types.extra.items[record.fields_start..][0..record.field_count]);
}

pub fn fieldTypes(types: *const Type, index: Index) []const Index {
    const record = types.extraData(StructRecord, types.structPayload(index));
    return @ptrCast(types.extra.items[record.fields_start + record.field_count ..][0..record.field_count]);
}

pub fn findField(types: *const Type, index: Index, name: String) ?u32 {
    const wanted = types.stringBytes(name);
    for (types.fieldNames(index), 0..) |field, at| {
        if (std.mem.eql(u8, types.stringBytes(field), wanted)) return @intCast(at);
    }
    return null;
}

// Strings

pub fn internString(types: *Type, gpa: Allocator, bytes: []const u8) Allocator.Error!String {
    if (bytes.len == 0) return .empty;
    const at: u32 = @intCast(types.strings.items.len);
    try types.strings.appendSlice(gpa, bytes);
    try types.strings.append(gpa, 0);
    return @enumFromInt(at);
}

pub fn stringBytes(types: *const Type, name: String) [:0]const u8 {
    const from = types.strings.items[@intFromEnum(name)..];
    const len = std.mem.indexOfScalar(u8, from, 0).?;
    return from[0..len :0];
}

// Spelling

pub fn spell(types: *const Type, ty: Index, arena: Allocator) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    types.write(ty, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn write(types: *const Type, ty: Index, out: *Io.Writer) Io.Writer.Error!void {
    if (builtinName(ty)) |name| return out.writeAll(name);

    switch (types.keyOf(ty)) {
        .builtin => unreachable, // always has a name
        .pointer => |pointer| {
            try out.writeAll(if (pointer.is_mutable) "*var " else "*");
            try types.write(pointer.pointee, out);
        },
        .struct_type => try out.writeAll(types.stringBytes(types.structName(ty))),
        .func => |func| {
            try out.writeAll("fn(");
            for (func.params, 0..) |param, position| {
                if (position > 0) try out.writeAll(", ");
                try types.write(param, out);
            }
            try out.writeAll(") ");
            try types.write(func.return_type, out);
        },
    }
}

// Storage. Nothing below is visible outside this file: a `Key` describes identity,
// an `Entry` stores it, and the deduplicating map looks it up.

/// All that keeps one nominal type apart from another. Minted here rather than derived
/// from the declaration site, so two files cannot mint the same one.
const NominalId = enum(u32) { _ };

/// What `intern` looks a type up by. Never stored, and excludes anything derived.
const Key = union(enum) {
    builtin: Index,
    pointer: Pointer,
    /// Keyed on the declaration, never the shape, so the body can arrive later.
    struct_type: NominalId,
    func: Func,

    const Pointer = struct { pointee: Index, is_mutable: bool };

    /// `std.meta.eql` would compare the params slice by pointer, so this stays by hand.
    fn eql(a: Key, b: Key) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .builtin => |x| x == b.builtin,
            .pointer => |x| x.pointee == b.pointer.pointee and
                x.is_mutable == b.pointer.is_mutable,
            .struct_type => |x| x == b.struct_type,
            .func => |x| x.return_type == b.func.return_type and
                std.mem.eql(Index, x.params, b.func.params),
        };
    }

    /// Deep, so `func.params` hashes by content, matching `eql`.
    fn hash(key: Key) u32 {
        var hasher: std.hash.Wyhash = .init(0);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        return @truncate(hasher.final());
    }
};

/// A `Key` in stored form. A struct's name and fields live in `extra` rather than in
/// its key, so `defineStruct` can fill them in without changing identity.
const Entry = struct {
    data: Data,
    /// Decided when the entry becomes complete.
    is_flat: bool,
};

const Data = union(enum) {
    builtin,
    pointer: Key.Pointer,
    struct_type: u32,
    /// Locates a `FuncRecord`, then its parameter types.
    func: u32,
};

const StructRecord = struct {
    id: NominalId,
    name: String,
    field_count: u32,
    /// Locates `field_count` names then `field_count` types.
    fields_start: u32,

    const body_undefined = std.math.maxInt(u32);
};

const FuncRecord = struct {
    return_type: Index,
    param_count: u32,
};

/// Reads a record stored one `u32` per field, in declaration order.
fn extraData(types: *const Type, comptime T: type, at: u32) T {
    var record: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, at..) |field, i| {
        const raw = types.extra.items[i];
        @field(record, field.name) = if (comptime field.type == u32) raw else @enumFromInt(raw);
    }
    return record;
}

fn setExtra(types: *Type, at: u32, record: anytype) void {
    inline for (@typeInfo(@TypeOf(record)).@"struct".fields, at..) |field, i| {
        const value = @field(record, field.name);
        types.extra.items[i] = if (comptime field.type == u32) value else @intFromEnum(value);
    }
}

fn addExtra(types: *Type, gpa: Allocator, record: anytype) Allocator.Error!u32 {
    const len = @typeInfo(@TypeOf(record)).@"struct".fields.len;
    const at: u32 = @intCast(types.extra.items.len);
    try types.extra.resize(gpa, at + len);
    types.setExtra(at, record);
    return at;
}

fn structPayload(types: *const Type, index: Index) u32 {
    return switch (types.entries.items(.data)[@intFromEnum(index)]) {
        .struct_type => |at| at,
        else => unreachable, // asked of a type that is not a struct
    };
}

const KeyAdapter = struct {
    types: *const Type,

    pub fn hash(_: KeyAdapter, key: Key) u32 {
        return key.hash();
    }

    pub fn eql(adapter: KeyAdapter, key: Key, _: void, position: usize) bool {
        return adapter.types.keyOf(@enumFromInt(position)).eql(key);
    }
};

fn intern(types: *Type, gpa: Allocator, key: Key) Allocator.Error!Index {
    const found = try types.dedup.getOrPutAdapted(gpa, key, KeyAdapter{ .types = types });
    if (found.found_existing) return @enumFromInt(found.index);

    errdefer _ = types.dedup.pop();
    assert(found.index == types.entries.len);

    const entry: Entry = switch (key) {
        .builtin => |builtin| .{
            .data = .builtin,
            .is_flat = switch (builtin) {
                .str, .Arena => false,
                else => true,
            },
        },
        .pointer => |pointer| .{ .data = .{ .pointer = pointer }, .is_flat = false },
        .struct_type => |id| .{
            .data = .{ .struct_type = try types.addExtra(gpa, StructRecord{
                .id = id,
                .name = .empty,
                .field_count = 0,
                .fields_start = StructRecord.body_undefined,
            }) },
            // Unknowable until the body arrives.
            .is_flat = false,
        },
        .func => |func| blk: {
            const at = try types.addExtra(gpa, FuncRecord{
                .return_type = func.return_type,
                .param_count = @intCast(func.params.len),
            });
            try types.extra.appendSlice(gpa, @ptrCast(func.params));
            // Code outlives every arena.
            break :blk .{ .data = .{ .func = at }, .is_flat = true };
        },
    };

    try types.entries.append(gpa, entry);
    return @enumFromInt(found.index);
}

/// A nominal type's body is not part of this. See `fieldTypes`.
fn keyOf(types: *const Type, index: Index) Key {
    return switch (types.entries.items(.data)[@intFromEnum(index)]) {
        .builtin => .{ .builtin = index },
        .pointer => |pointer| .{ .pointer = pointer },
        .struct_type => |at| .{
            .struct_type = types.extraData(StructRecord, at).id,
        },
        .func => |at| blk: {
            const record = types.extraData(FuncRecord, at);
            const params_at = at + @typeInfo(FuncRecord).@"struct".fields.len;
            break :blk .{ .func = .{
                .return_type = record.return_type,
                .params = @ptrCast(types.extra.items[params_at..][0..record.param_count]),
            } };
        },
    };
}
