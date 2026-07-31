const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Source = @import("Source.zig");
const Token = @import("Token.zig");

source: [:0]const u8,
cursor: u32,
/// The last tag returned, for the newline rule.
previous: Token.Tag,

pub const TokenList = std.MultiArrayList(Token);

const Tokenizer = @This();

pub fn init(source: [:0]const u8) Tokenizer {
    assert(source.len <= Source.bytes_max);

    const bom: u32 = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0;
    return .{ .source = source, .cursor = bom, .previous = .semi };
}

pub fn tokenizeAll(gpa: Allocator, source: [:0]const u8, tokens: *TokenList) Allocator.Error!void {
    assert(tokens.len == 0);

    try tokens.ensureTotalCapacity(gpa, @divFloor(source.len, 5) + 2);

    var tokenizer: Tokenizer = .init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;
    }

    assert(tokens.len > 0);
    assert(tokens.items(.tag)[tokens.len - 1] == .eof);
}

/// The next token, cursor left just past it.
pub fn next(tokenizer: *Tokenizer) Token {
    assert(tokenizer.cursor <= tokenizer.source.len);

    const source = tokenizer.source;
    var cursor = tokenizer.cursor;
    var start = cursor;

    const tag: Token.Tag = state: switch (State.start) {
        .start => switch (source[cursor]) {
            ' ', '\t', '\r' => {
                while (is_blank[source[cursor]]) cursor += 1;
                start = cursor;
                continue :state .start;
            },
            0 => {
                if (cursor != source.len) continue :state .invalid;
                // a file ending without a newline still ends its last statement
                if (Token.endsStatement(tokenizer.previous)) break :state .semi;
                break :state .eof;
            },
            '\n' => {
                cursor += 1;
                if (Token.endsStatement(tokenizer.previous)) break :state .semi;
                start = cursor;
                continue :state .start;
            },

            '(' => break :state step(&cursor, .l_paren),
            ')' => break :state step(&cursor, .r_paren),
            '{' => break :state step(&cursor, .l_brace),
            '}' => break :state step(&cursor, .r_brace),
            '[' => break :state step(&cursor, .l_bracket),
            ']' => break :state step(&cursor, .r_bracket),
            ',' => break :state step(&cursor, .comma),
            '.' => break :state step(&cursor, .dot),
            ':' => break :state step(&cursor, .colon),
            ';' => break :state step(&cursor, .semi),
            '|' => break :state step(&cursor, .pipe),
            '&' => break :state step(&cursor, .ampersand),
            '?' => break :state step(&cursor, .question),
            '+' => break :state step(&cursor, .plus),
            '-' => break :state step(&cursor, .minus),
            '*' => break :state step(&cursor, .star),
            '%' => break :state step(&cursor, .percent),

            'a'...'z', 'A'...'Z', '_' => continue :state .ident,
            '0'...'9' => continue :state .number,
            '=' => break :state pair(source, &cursor, '=', .eq_eq, .eq),
            '!' => break :state pair(source, &cursor, '=', .bang_eq, .bang),
            '<' => break :state pair(source, &cursor, '=', .lt_eq, .lt),
            '>' => break :state pair(source, &cursor, '=', .gt_eq, .gt),
            '/' => continue :state .slash,

            else => continue :state .invalid,
        },

        .ident => {
            assert(is_ident[source[cursor]]);
            while (is_ident[source[cursor]]) cursor += 1;
            assert(cursor > start);
            break :state Token.keywordOrIdent(source[start..cursor]);
        },

        .number => {
            while (is_ident[source[cursor]]) cursor += 1;
            assert(cursor > start);
            switch (source[cursor]) {
                '.' => switch (source[cursor + 1]) {
                    '0'...'9' => {
                        cursor += 1;
                        continue :state .number;
                    },
                    else => break :state .number,
                },
                '+', '-' => switch (source[cursor - 1]) {
                    'e', 'E', 'p', 'P' => {
                        cursor += 1;
                        continue :state .number;
                    },
                    else => break :state .number,
                },
                else => break :state .number,
            }
        },

        .slash => {
            assert(source[cursor] == '/');
            cursor += 1;
            if (source[cursor] == '/') continue :state .comment_start;
            break :state .slash;
        },

        .comment_start => {
            assert(source[cursor] == '/');
            cursor += 1;
            // `//!` is the file, `///` the declaration below, `////` just a comment
            if (source[cursor] == '!') continue :state .file_doc_comment;
            if (source[cursor] == '/') {
                if (source[cursor + 1] == '/') continue :state .line_comment;
                continue :state .doc_comment;
            }
            continue :state .line_comment;
        },

        // restart so the newline and eof rules see the pre-comment `previous`
        .line_comment => {
            cursor = endOfLine(source, cursor);
            start = cursor;
            continue :state .start;
        },

        .doc_comment => {
            cursor = endOfLine(source, cursor);
            assert(cursor >= start + 3);
            break :state .doc_comment;
        },

        .file_doc_comment => {
            cursor = endOfLine(source, cursor);
            assert(cursor >= start + 3);
            break :state .file_doc_comment;
        },

        .invalid => {
            @branchHint(.cold);
            cursor += 1;
            if (cursor == source.len) break :state .invalid;
            if (is_token_start[source[cursor]]) break :state .invalid;
            continue :state .invalid;
        },
    };

    assert(cursor <= source.len);
    assert(start <= cursor);

    // every token consumes input, except the `.semi` inserted at the end of file
    if (cursor == tokenizer.cursor) {
        assert(tag == .semi or tag == .eof);
        assert(cursor == source.len);
    }

    tokenizer.cursor = cursor;
    tokenizer.previous = tag;
    return .{ .tag = tag, .start = start };
}

/// The byte just past a token, rescanned, which is why none stores a length.
pub fn tokenEnd(source: [:0]const u8, tag: Token.Tag, start: u32) u32 {
    assert(start <= source.len);

    if (tag.lexeme()) |text| return start + @as(u32, @intCast(text.len));
    if (tag == .eof) return start;

    var tokenizer: Tokenizer = .{ .source = source, .cursor = start, .previous = .semi };
    _ = tokenizer.next();

    assert(tokenizer.cursor >= start);
    return tokenizer.cursor;
}

/// Where the scan is inside one token.
const State = enum {
    start,
    ident,
    number,
    slash,
    comment_start,
    line_comment,
    doc_comment,
    file_doc_comment,
    invalid,
};

/// A one byte token.
fn step(cursor: *u32, tag: Token.Tag) Token.Tag {
    assert(tag.lexeme() != null);
    assert(tag.lexeme().?.len == 1);
    cursor.* += 1;
    return tag;
}

/// One byte, or two when `second` follows.
fn pair(
    source: [:0]const u8,
    cursor: *u32,
    second: u8,
    if_paired: Token.Tag,
    if_alone: Token.Tag,
) Token.Tag {
    assert(if_paired.lexeme().?.len == 2);
    assert(if_alone.lexeme().?.len == 1);

    cursor.* += 1;
    if (source[cursor.*] != second) return if_alone;
    cursor.* += 1;
    return if_paired;
}

/// Bounded by `Source.bytes_max`, which is what keeps every offset a `u32`.
fn endOfLine(source: [:0]const u8, from: u32) u32 {
    assert(from <= source.len);
    const newline = std.mem.indexOfScalarPos(u8, source, from, '\n') orelse source.len;
    assert(newline >= from);
    return @intCast(newline);
}

const is_blank = classOf(" \t\r");
const is_ident = classOf("_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");
const is_token_start = classOf(" \t\r\n_0123456789abcdefghijklmnopqrstuvwxyz" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ(){}[],.:;|&?=!<>+-*/%");

fn classOf(comptime members: []const u8) [256]bool {
    comptime assert(members.len > 0);
    var table: [256]bool = @splat(false);
    for (members) |byte| table[byte] = true;
    return table;
}

fn complementOf(comptime members: []const u8) [256]bool {
    comptime assert(members.len > 0);
    var table: [256]bool = @splat(true);
    for (members) |byte| table[byte] = false;
    return table;
}

const testing = std.testing;

fn expectTags(source: [:0]const u8, expected: []const Token.Tag) !void {
    var tokenizer: Tokenizer = .init(source);
    for (expected) |want| try testing.expectEqual(want, tokenizer.next().tag);
    try testing.expectEqual(Token.Tag.eof, tokenizer.next().tag);
}

test "a newline after a value ends the statement" {
    try expectTags("let x = 1\nlet y = 2\n", &.{
        .kw_let, .ident, .eq, .number, .semi,
        .kw_let, .ident, .eq, .number, .semi,
    });
}

test "a newline after an operator does not" {
    try expectTags("let x = 1 +\n2\n", &.{ .kw_let, .ident, .eq, .number, .plus, .number, .semi });
}

test "the last line ends without a newline of its own" {
    try expectTags("return x", &.{ .kw_return, .ident, .semi });
}

test "a comment does not change what came before it" {
    try expectTags("x // note\ny", &.{ .ident, .semi, .ident, .semi });
    try expectTags("x +  // note\ny", &.{ .ident, .plus, .ident, .semi });
}

test "a doc comment is its own token" {
    try expectTags("/// doc\nfn f() {}", &.{
        .doc_comment, .kw_fn, .ident, .l_paren, .r_paren, .l_brace, .r_brace, .semi,
    });
    try expectTags("//// not doc\nfn", &.{.kw_fn});
}

test "a file doc comment is a tag of its own" {
    try expectTags("//! about this file\nfn f() {}", &.{
        .file_doc_comment, .kw_fn, .ident, .l_paren, .r_paren, .l_brace, .r_brace, .semi,
    });
    // three kinds of comment, told apart by the character after the slashes
    try expectTags("//! a\n/// b\n// c\nfn", &.{ .file_doc_comment, .doc_comment, .kw_fn });
}

test "blank lines and leading newlines emit nothing" {
    try expectTags("\n\n\nx\n\n\n", &.{ .ident, .semi });
}

test "a closing bracket ends a statement, an opening one does not" {
    try expectTags("f(\na\n)\n", &.{ .ident, .l_paren, .ident, .semi, .r_paren, .semi });
    try expectTags("type A = B[C]\n", &.{
        .kw_type, .ident, .eq, .ident, .l_bracket, .ident, .r_bracket, .semi,
    });
}

test "invalid bytes gather into one token" {
    try expectTags("\xFF\xFE x", &.{ .invalid, .ident, .semi });
    try expectTags("\xFF\n1", &.{ .invalid, .semi, .number, .semi });
}

test "a byte order mark is skipped" {
    try expectTags("\xEF\xBB\xBFx", &.{ .ident, .semi });
}

// a rescan from a token start must land where the first scan did, which is
// what lets a token store no length
test "tokenEnd agrees with the scan that produced the token" {
    const source: [:0]const u8 = "hello 12.5 \"a\\nb\" /// doc\n<= orelse";
    var tokenizer: Tokenizer = .init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        // an inserted `.semi` stands on a newline, so its text is not its lexeme
        if (token.tag == .semi) continue;
        try testing.expectEqual(tokenizer.cursor, tokenEnd(source, token.tag, token.start));
    }
}
