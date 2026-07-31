//! How far apart two names are, for a "did you mean" suggestion.

const std = @import("std");

/// Bounded Levenshtein distance, enough to rank a typo. Long names are cut
/// off, since a suggestion past forty characters convinces nobody.
pub fn between(a: []const u8, b: []const u8) u32 {
    const cap = 40;
    const from = a[0..@min(a.len, cap)];
    const to = b[0..@min(b.len, cap)];

    var row: [cap + 1]u32 = undefined;
    for (0..to.len + 1) |column| row[column] = @intCast(column);

    for (from, 1..) |byte, at| {
        var corner = row[0];
        row[0] = @intCast(at);
        for (to, 1..) |other, column| {
            const cost: u32 = if (byte == other) 0 else 1;
            const replaced = corner + cost;
            const inserted = row[column - 1] + 1;
            const removed = row[column] + 1;
            corner = row[column];
            row[column] = @min(replaced, @min(inserted, removed));
        }
    }
    return row[to.len];
}
