//! Token tags and the comptime tables the tokenizer and parser dispatch on.

const std = @import("std");
const assert = std.debug.assert;

const Token = @This();

tag: Tag,
start: u32,

comptime {
    assert(@sizeOf(Tag) == 1);
    assert(@sizeOf(Token) == 8);
}

pub const Tag = enum(u8) {
    invalid,
    eof,

    // Variable-length tags.
    ident,
    number,
    str,
    doc_comment,

    // Keywords.
    kw_and,
    kw_false,
    kw_fn,
    kw_let,
    kw_or,
    kw_pub,
    kw_return,
    kw_struct,
    kw_true,
    kw_use,
    kw_var,

    l_paren,
    r_paren,
    l_brace,
    r_brace,
    comma,
    dot,
    colon,
    /// Written, or inserted at a newline. The parser cannot tell, and that is the point.
    semi,

    eq,
    eq_eq,
    bang,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    plus,
    minus,
    star,
    slash,
    percent,

    /// The fixed text of this token, or null if its text varies.
    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid, .eof, .ident, .number, .str, .doc_comment => null,

            .kw_and => "and",
            .kw_false => "false",
            .kw_fn => "fn",
            .kw_let => "let",
            .kw_or => "or",
            .kw_pub => "pub",
            .kw_return => "return",
            .kw_struct => "struct",
            .kw_true => "true",
            .kw_use => "use",
            .kw_var => "var",

            .l_paren => "(",
            .r_paren => ")",
            .l_brace => "{",
            .r_brace => "}",
            .comma => ",",
            .dot => ".",
            .colon => ":",
            .semi => ";",

            .eq => "=",
            .eq_eq => "==",
            .bang => "!",
            .bang_eq => "!=",
            .lt => "<",
            .lt_eq => "<=",
            .gt => ">",
            .gt_eq => ">=",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
        };
    }

    /// How this token is named in a diagnostic.
    pub fn symbol(tag: Tag) []const u8 {
        return tag.lexeme() orelse switch (tag) {
            .invalid => "invalid bytes",
            .eof => "end of file",
            .ident => "an identifier",
            .number => "a number",
            .str => "a string literal",
            .doc_comment => "a documentation comment",
            else => unreachable,
        };
    }
};

pub const tag_count = @typeInfo(Tag).@"enum".fields.len;

pub const Traits = packed struct(u8) {
    /// A newline after this token ends a statement, so a synthetic `.semi` is emitted.
    ends_stmt: bool = false,
    /// Lexeme length, 0 means variable-length and the end must be rescanned.
    lexeme_len: u7 = 0,
};

pub const traits: [tag_count]Traits = blk: {
    var table: [tag_count]Traits = @splat(.{});
    for (std.enums.values(Tag)) |tag| table[@intFromEnum(tag)] = .{
        .ends_stmt = switch (tag) {
            .ident, .number, .str, .r_paren, .r_brace => true,
            .kw_return, .kw_true, .kw_false => true,
            else => false,
        },
        .lexeme_len = if (tag.lexeme()) |l| @intCast(l.len) else 0,
    };
    break :blk table;
};

// Keyword recognition

const keyword_list = [_]struct { []const u8, Tag }{
    .{ "and", .kw_and },
    .{ "false", .kw_false },
    .{ "fn", .kw_fn },
    .{ "let", .kw_let },
    .{ "or", .kw_or },
    .{ "pub", .kw_pub },
    .{ "return", .kw_return },
    .{ "struct", .kw_struct },
    .{ "true", .kw_true },
    .{ "use", .kw_use },
    .{ "var", .kw_var },
};

comptime {
    for (keyword_list) |kw| {
        // A 9-character keyword would break single-compare matching.
        if (kw[0].len > 8) @compileError("keyword '" ++ kw[0] ++ "' exceeds 8 bytes");
        if (!std.mem.eql(u8, kw[1].lexeme().?, kw[0]))
            @compileError("keyword '" ++ kw[0] ++ "' disagrees with Tag.lexeme");
    }
}

const kw_len = blk: {
    var lo: usize = 8;
    var hi: usize = 0;
    for (keyword_list) |kw| {
        lo = @min(lo, kw[0].len);
        hi = @max(hi, kw[0].len);
    }
    break :blk .{ .min = lo, .max = hi };
};

/// Classifies an already-scanned identifier.
pub inline fn keywordOrIdent(src: [*]const u8, start: u32, len: u32) Tag {
    if (len < kw_len.min or len > kw_len.max) return .ident;
    const word = std.mem.readInt(u64, src[start..][0..8], .little);
    switch (len) {
        inline kw_len.min...kw_len.max => |n| {
            const masked = word & comptime if (n >= 8)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << (n * 8)) - 1;
            inline for (keyword_list) |kw| {
                if (comptime kw[0].len == n) {
                    if (masked == comptime packLittleEndian(kw[0])) return kw[1];
                }
            }
            return .ident;
        },
        else => return .ident,
    }
}

fn packLittleEndian(comptime s: []const u8) u64 {
    var w: u64 = 0;
    for (s, 0..) |c, i| w |= @as(u64, c) << @intCast(i * 8);
    return w;
}
