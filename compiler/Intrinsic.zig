//! The operations the compiler performs itself, reached as `intrinsic.name`.
//!
//! An intrinsic is not a function. It has no declaration, no body, and no
//! address. The checker knows its shape from the table here and its meaning
//! from `Check.checkIntrinsic`, which is where a new one is typed and lowered.

const std = @import("std");
const assert = std.debug.assert;

/// Spelled in source exactly as the tag is written.
pub const Intrinsic = enum {
    /// `intrinsic.ptr_cast[T](pointer)`, retyping a pointer without moving it.
    ptr_cast,

    /// What the checker validates before typing a call. Type rules live with
    /// the case that needs them, because no two intrinsics share one.
    pub const Shape = struct {
        type_params: u8,
        params: u8,
    };

    pub fn shape(intrinsic: Intrinsic) Shape {
        return switch (intrinsic) {
            .ptr_cast => .{ .type_params = 1, .params = 1 },
        };
    }

    pub fn fromName(text: []const u8) ?Intrinsic {
        assert(text.len > 0);
        return std.meta.stringToEnum(Intrinsic, text);
    }

    /// For a suggestion when a name is missed.
    pub const names = std.meta.fieldNames(Intrinsic);
};

/// Sized from the table, so a buffer holding one call's arguments cannot
/// overflow and no call site has to check.
pub const type_params_max = 1;
pub const params_max = 1;

comptime {
    assert(@typeInfo(Intrinsic).@"enum".fields.len > 0);
    for (std.enums.values(Intrinsic)) |intrinsic| {
        assert(intrinsic.shape().type_params <= type_params_max);
        assert(intrinsic.shape().params <= params_max);
    }
}
