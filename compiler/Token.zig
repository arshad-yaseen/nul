const std = @import("std");
const assert = std.debug.assert;

tag: Tag,
/// The end is rescanned by `Tokenizer.tokenEnd`, never stored.
start: u32,

pub const Tag = enum(u8) {
    /// Bytes that cannot begin a token.
    invalid,
    unterminated_str,
    eof,

    ident,
    number,
    str,
    /// A string holding at least one backslash, so only these need checking.
    str_escaped,
    /// `///` and the rest of its line. Belongs to the declaration below it.
    doc_comment,
    file_doc_comment,

    // `lexeme` below is the one place a keyword's spelling lives
    kw_and,
    kw_break,
    kw_catch,
    kw_continue,
    kw_defer,
    kw_else,
    kw_error,
    kw_false,
    kw_fn,
    kw_if,
    kw_let,
    kw_null,
    kw_or,
    kw_orelse,
    kw_pub,
    kw_return,
    kw_struct,
    kw_true,
    kw_try,
    kw_type,
    kw_use,
    kw_var,
    kw_while,

    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    dot,
    colon,
    /// Written, or inserted at a newline. The parser cannot tell.
    semi,
    /// Delimits a capture, `|err|`.
    pipe,
    ampersand,
    question,

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

    /// The fixed text of a tag, or null for the tags whose text is the source.
    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid, .unterminated_str, .eof => null,
            .ident, .number, .str, .str_escaped, .doc_comment, .file_doc_comment => null,

            .kw_and => "and",
            .kw_break => "break",
            .kw_catch => "catch",
            .kw_continue => "continue",
            .kw_defer => "defer",
            .kw_else => "else",
            .kw_error => "error",
            .kw_false => "false",
            .kw_fn => "fn",
            .kw_if => "if",
            .kw_let => "let",
            .kw_null => "null",
            .kw_or => "or",
            .kw_orelse => "orelse",
            .kw_pub => "pub",
            .kw_return => "return",
            .kw_struct => "struct",
            .kw_true => "true",
            .kw_try => "try",
            .kw_type => "type",
            .kw_use => "use",
            .kw_var => "var",
            .kw_while => "while",

            .l_paren => "(",
            .r_paren => ")",
            .l_brace => "{",
            .r_brace => "}",
            .l_bracket => "[",
            .r_bracket => "]",
            .comma => ",",
            .dot => ".",
            .colon => ":",
            .semi => ";",
            .pipe => "|",
            .ampersand => "&",
            .question => "?",

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

    /// How a message names this tag, a quoted lexeme, or a phrase.
    pub fn symbol(tag: Tag) []const u8 {
        const text = symbols[@intFromEnum(tag)];
        assert(text.len > 0);
        return text;
    }
};

/// A position in a token list.
pub const Index = enum(u32) {
    first = 0,
    _,

    /// The token `count` places later. Callers stay inside the list because
    /// every list ends with an `.eof` the cursor never passes.
    pub fn after(index: Index, count: u32) Index {
        assert(@intFromEnum(index) <= std.math.maxInt(u32) - count);
        return @enumFromInt(@intFromEnum(index) + count);
    }

    /// The token `count` places earlier.
    pub fn before(index: Index, count: u32) Index {
        assert(count > 0);
        assert(@intFromEnum(index) >= count);
        return @enumFromInt(@intFromEnum(index) - count);
    }

    pub fn int(index: Index) u32 {
        return @intFromEnum(index);
    }
};

pub const tag_count = @typeInfo(Tag).@"enum".fields.len;

const Token = @This();

comptime {
    assert(@sizeOf(Tag) == 1);
    assert(@sizeOf(Token) == 8);
    assert(@sizeOf(Index) == 4);
}

/// Whether a newline after this tag ends a statement. The two lexical errors
/// are here because a newline after a broken value still ends its statement.
pub fn endsStatement(tag: Tag) bool {
    return switch (tag) {
        .ident, .number, .str, .str_escaped, .unterminated_str, .invalid => true,
        .r_paren, .r_brace, .r_bracket => true,
        .kw_true, .kw_false, .kw_null => true,
        .kw_return, .kw_break, .kw_continue => true,
        else => false,
    };
}

pub fn keywordOrIdent(bytes: []const u8) Tag {
    assert(bytes.len > 0);

    if (bytes.len < keyword_length_min or bytes.len > keyword_length_max) return .ident;

    const entry = &keywords[hash(bytes[0], bytes[1], bytes[bytes.len - 1], @intCast(bytes.len))];
    if (entry.length != bytes.len) return .ident;
    if (std.mem.eql(u8, entry.text[0..bytes.len], bytes) == false) return .ident;

    assert(entry.tag != .ident);
    return entry.tag;
}

const keyword_length_min = 2;
const keyword_length_max = 8;
const keyword_slots = 32;

const Keyword = struct { text: [keyword_length_max]u8, length: u8, tag: Tag };

fn hash(first: u8, second: u8, last: u8, length: u32) u32 {
    assert(length >= keyword_length_min);
    assert(length <= keyword_length_max);
    const sum = @as(u32, first) + @as(u32, second) * 20 + @as(u32, last) * 22 + length * 11;
    return sum & (keyword_slots - 1);
}

/// Derived from `lexeme`, so the table cannot drift from the tags.
const keywords: [keyword_slots]Keyword = blk: {
    var table: [keyword_slots]Keyword = @splat(.{ .text = @splat(0), .length = 0, .tag = .ident });
    var filled = 0;
    for (std.enums.values(Tag)) |tag| {
        if (std.mem.startsWith(u8, @tagName(tag), "kw_") == false) continue;
        const text = tag.lexeme().?;
        assert(text.len >= keyword_length_min);
        assert(text.len <= keyword_length_max);

        const slot = hash(text[0], text[1], text[text.len - 1], text.len);
        if (table[slot].length != 0) @compileError("keyword hash collision on " ++ text);

        var entry: Keyword = .{ .text = @splat(0), .length = text.len, .tag = tag };
        @memcpy(entry.text[0..text.len], text);
        table[slot] = entry;
        filled += 1;
    }
    assert(filled > 0);
    assert(filled <= keyword_slots);
    break :blk table;
};

const symbols: [tag_count][]const u8 = blk: {
    var table: [tag_count][]const u8 = @splat("");
    for (std.enums.values(Tag)) |tag| {
        table[@intFromEnum(tag)] = switch (tag) {
            .invalid => "invalid bytes",
            .unterminated_str => "an unterminated string",
            .eof => "end of file",
            .ident => "an identifier",
            .number => "a number",
            .str, .str_escaped => "a string literal",
            .doc_comment => "a doc comment",
            .file_doc_comment => "a file doc comment",
            .semi => "the end of the line",
            else => quoted: {
                const text = tag.lexeme() orelse
                    @compileError("tag needs a phrase or a lexeme: " ++ @tagName(tag));
                break :quoted "'" ++ text ++ "'";
            },
        };
        assert(table[@intFromEnum(tag)].len > 0);
    }
    break :blk table;
};
