//! Identity and storage for types. Every distinct type has one `Index`, so "the same
//! type" is one integer compare.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const InternPool = @This();

/// `Index` is a position here.
entries: std.MultiArrayList(Entry),
/// Variable-length key and payload parts.
extra: std.ArrayList(u32),
/// NUL terminated. `String` is a position here.
strings: std.ArrayList(u8),
/// In lockstep with `entries`, so map position N describes type N.
dedup: std.AutoArrayHashMapUnmanaged(void, void),
next_nominal_id: u32,

/// All that keeps one nominal type apart from another. Minted here, not derived from the
/// declaration site, so two files cannot mint the same one.
pub const NominalId = enum(u32) { _ };

/// Not deduplicated, so a repeated name costs its bytes twice.
pub const String = enum(u32) { empty = 0, _ };

// Indices

/// The types that exist before any source is read, in seeding order. Every member up to
/// `poisoned` is spelled the way Nul spells it.
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
    /// What analysis yields once it has reported why it has no answer. Not `never`: that
    /// is a type a program can mean, and `let x: never = 10` is wrong where this is not.
    poisoned,
    _,
};

/// Null once `index` is past the builtins.
pub fn builtinName(index: Index) ?[]const u8 {
    inline for (@typeInfo(Index).@"enum".fields) |field| {
        if (@intFromEnum(index) == field.value) return field.name;
    }
    return null;
}

const aliases = std.StaticStringMap(Index).initComptime(.{
    .{ "int", Index.i64 },
    .{ "uint", Index.u64 },
});

pub fn builtinNamed(name: []const u8) ?Index {
    if (aliases.get(name)) |alias| return alias;
    inline for (@typeInfo(Index).@"enum".fields) |field| {
        if (field.value < @intFromEnum(Index.poisoned) and std.mem.eql(u8, field.name, name))
            return @enumFromInt(field.value);
    }
    return null;
}

// Keys

/// What `intern` looks a type up by. Never stored, and excludes anything derived.
pub const Key = union(enum) {
    /// Its own index. A builtin has no structure to describe it by.
    builtin: Index,
    pointer: Pointer,
    /// Keyed on the declaration, never the shape, so the body can arrive later.
    struct_type: NominalId,
    func: Func,

    pub const Pointer = struct { pointee: Index, is_mutable: bool };
    pub const Func = struct { params: []const Index, return_type: Index };

    pub fn eql(a: Key, b: Key) bool {
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

    pub fn hash(key: Key) u32 {
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(std.mem.asBytes(&std.meta.activeTag(key)));
        switch (key) {
            .builtin => |x| hasher.update(std.mem.asBytes(&x)),
            .pointer => |x| {
                hasher.update(std.mem.asBytes(&x.pointee));
                const mutable: u8 = @intFromBool(x.is_mutable);
                hasher.update(std.mem.asBytes(&mutable));
            },
            .struct_type => |x| hasher.update(std.mem.asBytes(&x)),
            .func => |x| {
                hasher.update(std.mem.sliceAsBytes(x.params));
                hasher.update(std.mem.asBytes(&x.return_type));
            },
        }
        return @truncate(hasher.final());
    }
};

// Storage

/// A `Key` in stored form. A struct's name and fields live here rather than in its key,
/// so `defineStruct` can fill them in without changing the hash it was interned under.
const Entry = struct {
    tag: Tag,
    /// Read according to `tag`.
    payload: u32,
    /// Decided when the entry becomes complete.
    is_flat: bool,
};

const Tag = enum(u8) {
    /// `payload` unused, a builtin is its own index.
    builtin,
    /// `payload` is the pointee. Mutability is the tag, not a payload bit.
    pointer,
    pointer_mut,
    /// `payload` locates a `StructRecord`.
    struct_type,
    /// `payload` locates the return type, the parameter count, then the parameters.
    func,
};

/// Four slots in `extra`. `fields_start_slot` locates `field_count` names followed by
/// `field_count` types.
const StructRecord = struct {
    const id_slot = 0;
    const name_slot = 1;
    const field_count_slot = 2;
    const fields_start_slot = 3;
    const slot_count = 4;
    const body_undefined = std.math.maxInt(u32);
};

/// A two-slot header in `extra`, then `param_count` parameter types.
const FuncRecord = struct {
    const return_type_slot = 0;
    const param_count_slot = 1;
    const slot_count = 2;
};

pub fn init(gpa: Allocator) Allocator.Error!InternPool {
    var pool: InternPool = .{
        .entries = .empty,
        .extra = .empty,
        .strings = .empty,
        .dedup = .empty,
        .next_nominal_id = 0,
    };
    errdefer pool.deinit(gpa);

    try pool.strings.append(gpa, 0); // so `String.empty` reads back empty

    inline for (@typeInfo(Index).@"enum".fields) |field| {
        const expected: Index = @enumFromInt(field.value);
        const actual = try pool.intern(gpa, .{ .builtin = expected });
        assert(actual == expected);
    }
    return pool;
}

pub fn deinit(pool: *InternPool, gpa: Allocator) void {
    pool.entries.deinit(gpa);
    pool.extra.deinit(gpa);
    pool.strings.deinit(gpa);
    pool.dedup.deinit(gpa);
    pool.* = undefined;
}

// Interning

const KeyAdapter = struct {
    pool: *const InternPool,

    pub fn hash(_: KeyAdapter, key: Key) u32 {
        return key.hash();
    }

    pub fn eql(adapter: KeyAdapter, key: Key, _: void, position: usize) bool {
        return adapter.pool.keyOf(@enumFromInt(position)).eql(key);
    }
};

pub fn intern(pool: *InternPool, gpa: Allocator, key: Key) Allocator.Error!Index {
    const found = try pool.dedup.getOrPutAdapted(gpa, key, KeyAdapter{ .pool = pool });
    if (found.found_existing) return @enumFromInt(found.index);

    errdefer _ = pool.dedup.pop();
    assert(found.index == pool.entries.len);

    const entry: Entry = switch (key) {
        .builtin => |builtin| .{
            .tag = .builtin,
            .payload = 0,
            .is_flat = switch (builtin) {
                .str, .Arena => false,
                else => true,
            },
        },
        .pointer => |pointer| .{
            .tag = if (pointer.is_mutable) .pointer_mut else .pointer,
            .payload = @intFromEnum(pointer.pointee),
            .is_flat = false,
        },
        .struct_type => |id| blk: {
            const at: u32 = @intCast(pool.extra.items.len);
            var record: [StructRecord.slot_count]u32 = undefined;
            record[StructRecord.id_slot] = @intFromEnum(id);
            record[StructRecord.name_slot] = @intFromEnum(String.empty);
            record[StructRecord.field_count_slot] = 0;
            record[StructRecord.fields_start_slot] = StructRecord.body_undefined;
            try pool.extra.appendSlice(gpa, &record);
            // Unknowable until the body arrives.
            break :blk .{ .tag = .struct_type, .payload = at, .is_flat = false };
        },
        .func => |func| blk: {
            const at: u32 = @intCast(pool.extra.items.len);
            var header: [FuncRecord.slot_count]u32 = undefined;
            header[FuncRecord.return_type_slot] = @intFromEnum(func.return_type);
            header[FuncRecord.param_count_slot] = @intCast(func.params.len);
            try pool.extra.appendSlice(gpa, &header);
            try pool.extra.appendSlice(gpa, @ptrCast(func.params));
            // Code outlives every arena.
            break :blk .{ .tag = .func, .payload = at, .is_flat = true };
        },
    };

    try pool.entries.append(gpa, entry);
    return @enumFromInt(found.index);
}

/// A nominal type's body is not part of this; see `structFieldTypes`.
pub fn keyOf(pool: *const InternPool, index: Index) Key {
    const entry = pool.entries.get(@intFromEnum(index));
    return switch (entry.tag) {
        .builtin => .{ .builtin = index },
        .pointer, .pointer_mut => .{ .pointer = .{
            .pointee = @enumFromInt(entry.payload),
            .is_mutable = entry.tag == .pointer_mut,
        } },
        .struct_type => .{
            .struct_type = @enumFromInt(pool.extra.items[entry.payload + StructRecord.id_slot]),
        },
        .func => blk: {
            const count = pool.extra.items[entry.payload + FuncRecord.param_count_slot];
            const params_at = entry.payload + FuncRecord.slot_count;
            break :blk .{ .func = .{
                .return_type = @enumFromInt(
                    pool.extra.items[entry.payload + FuncRecord.return_type_slot],
                ),
                .params = @ptrCast(pool.extra.items[params_at..][0..count]),
            } };
        },
    };
}

/// Whether a value can contain an access path to arena memory. `Arena.copy` requires it,
/// since copying a pointer relabels its region without moving what it points at.
pub fn isFlat(pool: *const InternPool, index: Index) bool {
    assert(pool.isDefined(index));
    return pool.entries.items(.is_flat)[@intFromEnum(index)];
}

// Nominal types

/// Mints the index before the body is known, so `*Node` can be interned while `Node`'s
/// fields still resolve. Pair with `defineStruct`.
pub fn declareStruct(pool: *InternPool, gpa: Allocator, name: String) Allocator.Error!Index {
    const id: NominalId = @enumFromInt(pool.next_nominal_id);
    pool.next_nominal_id += 1;
    const index = try pool.intern(gpa, .{ .struct_type = id });
    pool.extra.items[pool.structRecordAt(index) + StructRecord.name_slot] = @intFromEnum(name);
    return index;
}

/// Also the moment flatness is decided.
pub fn defineStruct(
    pool: *InternPool,
    gpa: Allocator,
    index: Index,
    field_names: []const String,
    field_types: []const Index,
) Allocator.Error!void {
    assert(field_names.len == field_types.len);
    assert(!pool.isDefined(index));

    const fields_at: u32 = @intCast(pool.extra.items.len);
    try pool.extra.appendSlice(gpa, @ptrCast(field_names));
    try pool.extra.appendSlice(gpa, @ptrCast(field_types));

    const record = pool.structRecordAt(index);
    pool.extra.items[record + StructRecord.field_count_slot] = @intCast(field_names.len);
    pool.extra.items[record + StructRecord.fields_start_slot] = fields_at;

    var flat = true;
    for (field_types) |field_type| {
        if (!pool.isFlat(field_type)) {
            flat = false;
            break;
        }
    }
    pool.entries.items(.is_flat)[@intFromEnum(index)] = flat;
}

/// False only between `declareStruct` and `defineStruct`.
pub fn isDefined(pool: *const InternPool, index: Index) bool {
    const entry = pool.entries.get(@intFromEnum(index));
    if (entry.tag != .struct_type) return true;
    const slot = entry.payload + StructRecord.fields_start_slot;
    return pool.extra.items[slot] != StructRecord.body_undefined;
}

pub fn structName(pool: *const InternPool, index: Index) String {
    return @enumFromInt(pool.extra.items[pool.structRecordAt(index) + StructRecord.name_slot]);
}

pub fn structFieldNames(pool: *const InternPool, index: Index) []const String {
    const record = pool.structRecordAt(index);
    const count = pool.extra.items[record + StructRecord.field_count_slot];
    const fields_at = pool.extra.items[record + StructRecord.fields_start_slot];
    return @ptrCast(pool.extra.items[fields_at..][0..count]);
}

pub fn structFieldTypes(pool: *const InternPool, index: Index) []const Index {
    const record = pool.structRecordAt(index);
    const count = pool.extra.items[record + StructRecord.field_count_slot];
    const fields_at = pool.extra.items[record + StructRecord.fields_start_slot];
    return @ptrCast(pool.extra.items[fields_at + count ..][0..count]);
}

pub fn findStructField(pool: *const InternPool, index: Index, name: String) ?u32 {
    const wanted = pool.stringBytes(name);
    for (pool.structFieldNames(index), 0..) |field_name, position| {
        if (std.mem.eql(u8, pool.stringBytes(field_name), wanted)) return @intCast(position);
    }
    return null;
}

fn structRecordAt(pool: *const InternPool, index: Index) u32 {
    const entry = pool.entries.get(@intFromEnum(index));
    assert(entry.tag == .struct_type);
    return entry.payload;
}

// Strings

pub fn internString(
    pool: *InternPool,
    gpa: Allocator,
    bytes: []const u8,
) Allocator.Error!String {
    if (bytes.len == 0) return .empty;
    const at: u32 = @intCast(pool.strings.items.len);
    try pool.strings.appendSlice(gpa, bytes);
    try pool.strings.append(gpa, 0);
    return @enumFromInt(at);
}

pub fn stringBytes(pool: *const InternPool, name: String) [:0]const u8 {
    const from = pool.strings.items[@intFromEnum(name)..];
    const len = std.mem.indexOfScalar(u8, from, 0).?;
    return from[0..len :0];
}
