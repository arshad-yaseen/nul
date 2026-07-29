//! Token tags, and what the tokenizer and parser dispatch on.

const std = @import("std");
const assert = std.debug.assert;

const Token = @This();

tag: Tag,
/// Byte offset in the source. The end is rescanned by `Tokenizer.tokenEnd`, never stored.
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
    kw_break,
    kw_continue,
    kw_else,
    kw_false,
    kw_fn,
    kw_for,
    kw_if,
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

    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid, .eof, .ident, .number, .str, .doc_comment => null,

            .kw_and => "and",
            .kw_break => "break",
            .kw_continue => "continue",
            .kw_else => "else",
            .kw_false => "false",
            .kw_fn => "fn",
            .kw_for => "for",
            .kw_if => "if",
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

/// A newline after this token ends a statement, so a synthetic `.semi` is emitted.
pub fn endsStatement(tag: Tag) bool {
    return switch (tag) {
        .ident, .number, .str, .r_paren, .r_brace => true,
        .kw_return, .kw_true, .kw_false, .kw_break, .kw_continue => true,
        else => false,
    };
}

// Keyword recognition

/// Derived from `lexeme`, so the table cannot drift from the tags.
const keywords = std.StaticStringMap(Tag).initComptime(blk: {
    var kvs: []const struct { []const u8, Tag } = &.{};
    for (std.enums.values(Tag)) |tag| {
        if (std.mem.startsWith(u8, @tagName(tag), "kw_")) {
            kvs = kvs ++ [_]struct { []const u8, Tag }{.{ tag.lexeme().?, tag }};
        }
    }
    break :blk kvs;
});

pub fn keywordOrIdent(bytes: []const u8) Tag {
    return keywords.get(bytes) orelse .ident;
}
