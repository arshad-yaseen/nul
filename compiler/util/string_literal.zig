const std = @import("std");
const assert = std.debug.assert;

/// Every escape the language has.
pub const escapes = "\\n \\t \\r \\\\ \\\"";

/// The offset within `raw` of the first backslash that begins nothing, or null
/// when every escape in it means something. `raw` is the text of a
/// `.str_escaped` token, both quotes included.
pub fn badEscape(raw: []const u8) ?u32 {
    assert(raw.len >= 2);
    assert(raw[0] == '"');
    assert(raw[raw.len - 1] == '"');

    const body = raw[1 .. raw.len - 1];
    assert(body.len + 2 == raw.len);

    var cursor: u32 = 0;
    while (std.mem.indexOfScalarPos(u8, body, cursor, '\\')) |backslash| {
        assert(backslash < body.len);
        const escaped = if (backslash + 1 < body.len) body[backslash + 1] else 0;
        switch (escaped) {
            'n', 't', 'r', '\\', '"' => {},
            else => return @intCast(backslash + 1),
        }
        cursor = @intCast(backslash + 2);
    }
    return null;
}

const testing = std.testing;

test "the escapes the language has" {
    try testing.expectEqual(null, badEscape("\"\""));
    try testing.expectEqual(null, badEscape("\"hello\""));
    try testing.expectEqual(null, badEscape("\"\\n\\t\\r\\\\\\\"\""));
    try testing.expectEqual(null, badEscape("\"a\\\\b\""));
}

test "an escape the language does not have" {
    try testing.expectEqual(1, badEscape("\"\\q\""));
    try testing.expectEqual(3, badEscape("\"ab\\0\""));
    try testing.expectEqual(4, badEscape("\"a\\\\\\q\""));
}
