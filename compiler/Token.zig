const std = @import("std");
const assert = std.debug.assert;

tag: Tag,
/// The end is rescanned by `Tokenizer.tokenEnd`, never stored.
start: u32,

pub const Tag = enum(u8) {
    /// Bytes that cannot begin a token.
    invalid,
    eof,

    ident,
    number,
    /// `///` to end of line, belonging to the declaration below.
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

    /// Fixed text, or null when the text is the source itself.
    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid, .eof => null,
            .ident, .number, .doc_comment, .file_doc_comment => null,

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

    /// How a message names this tag.
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

    pub fn before(index: Index, count: u32) Index {
        assert(count > 0);
        assert(@intFromEnum(index) >= count);
        return @enumFromInt(@intFromEnum(index) - count);
    }

    pub fn from(raw: usize) Index {
        assert(raw < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(raw)));
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

/// Whether a newline after this tag ends a statement. A broken value counts,
/// so its line still ends.
pub fn endsStatement(tag: Tag) bool {
    return switch (tag) {
        .ident, .number, .invalid => true,
        .r_paren, .r_brace, .r_bracket => true,
        .kw_true, .kw_false, .kw_null => true,
        .kw_return, .kw_break, .kw_continue => true,
        else => false,
    };
}

pub fn keywordOrIdent(bytes: []const u8) Tag {
    assert(bytes.len > 0);
    return keywords.get(bytes) orelse .ident;
}

/// Derived from `lexeme`, so the table cannot drift from the tags.
const keywords = build: {
    const tags = std.enums.values(Tag);
    var entries: [tags.len]struct { []const u8, Tag } = undefined;
    var count = 0;
    for (tags) |tag| {
        if (std.mem.startsWith(u8, @tagName(tag), "kw_") == false) continue;
        entries[count] = .{ tag.lexeme().?, tag };
        count += 1;
    }
    assert(count > 0);
    break :build std.StaticStringMap(Tag).initComptime(entries[0..count].*);
};

const symbols: [tag_count][]const u8 = blk: {
    var table: [tag_count][]const u8 = @splat("");
    for (std.enums.values(Tag)) |tag| {
        table[@intFromEnum(tag)] = switch (tag) {
            .invalid => "invalid bytes",
            .eof => "end of file",
            .ident => "an identifier",
            .number => "a number",
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
