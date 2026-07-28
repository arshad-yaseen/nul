const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @import("Token.zig");

const Tokenizer = @This();

src: [:0]const u8,
index: u32,
/// Last significant tag, for the automatic-semicolon rule. Comments do not update it,
/// so a newline after `x // note` still ends the statement.
prev: Token.Tag,

pub fn init(src: [:0]const u8) Tokenizer {
    const bom: u32 = if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) 3 else 0;
    return .{ .src = src, .index = bom, .prev = .semi };
}

const State = enum {
    start,
    ident,
    number,
    str,
    str_backslash,
    slash,
    line_comment,
    doc_comment_start,
    doc_comment,
    eq,
    bang,
    lt,
    gt,
    invalid,
};

pub fn next(self: *Tokenizer) Token {
    const src = self.src;
    var start = self.index;

    const tag: Token.Tag = state: switch (State.start) {
        .start => switch (src[self.index]) {
            0 => {
                if (self.index != src.len) continue :state .invalid;
                // A file ending without a newline still ends its last statement.
                if (Token.traits[@intFromEnum(self.prev)].ends_stmt) break :state .semi;
                break :state .eof;
            },
            ' ', '\t', '\r' => {
                self.index += 1;
                start = self.index;
                continue :state .start;
            },
            '\n' => {
                if (Token.traits[@intFromEnum(self.prev)].ends_stmt) {
                    self.index += 1;
                    break :state .semi;
                }
                self.index += 1;
                start = self.index;
                continue :state .start;
            },

            'a'...'z', 'A'...'Z', '_' => continue :state .ident,
            '0'...'9' => continue :state .number,
            '"' => {
                self.index += 1;
                continue :state .str;
            },

            '(' => break :state self.singleChar(.l_paren),
            ')' => break :state self.singleChar(.r_paren),
            '{' => break :state self.singleChar(.l_brace),
            '}' => break :state self.singleChar(.r_brace),
            ',' => break :state self.singleChar(.comma),
            '.' => break :state self.singleChar(.dot),
            ':' => break :state self.singleChar(.colon),
            ';' => break :state self.singleChar(.semi),
            '+' => break :state self.singleChar(.plus),
            '-' => break :state self.singleChar(.minus),
            '*' => break :state self.singleChar(.star),
            '%' => break :state self.singleChar(.percent),

            '=' => continue :state .eq,
            '!' => continue :state .bang,
            '<' => continue :state .lt,
            '>' => continue :state .gt,
            '/' => continue :state .slash,

            else => continue :state .invalid,
        },

        .ident => {
            self.index += 1;
            switch (src[self.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .ident,
                else => break :state Token.keywordOrIdent(src.ptr, start, self.index - start),
            }
        },

        .number => {
            self.index += 1;
            switch (src[self.index]) {
                '0'...'9', 'a'...'z', 'A'...'Z', '_' => continue :state .number,
                '.' => switch (src[self.index + 1]) {
                    '0'...'9' => {
                        self.index += 1;
                        continue :state .number;
                    },
                    else => break :state .number,
                },
                // An exponent's sign
                '+', '-' => switch (src[self.index - 1]) {
                    'e', 'E', 'p', 'P' => continue :state .number,
                    else => break :state .number,
                },
                else => break :state .number,
            }
        },

        .str => switch (src[self.index]) {
            0 => {
                if (self.index == src.len) break :state .invalid;
                self.index += 1;
                continue :state .str;
            },
            '\n' => break :state .invalid,
            '\\' => {
                self.index += 1;
                continue :state .str_backslash;
            },
            '"' => {
                self.index += 1;
                break :state .str;
            },
            else => {
                self.index += 1;
                continue :state .str;
            },
        },

        .str_backslash => switch (src[self.index]) {
            0 => {
                if (self.index == src.len) break :state .invalid;
                self.index += 1;
                continue :state .str;
            },
            '\n' => break :state .invalid,
            else => {
                self.index += 1;
                continue :state .str;
            },
        },

        .slash => {
            self.index += 1;
            switch (src[self.index]) {
                '/' => continue :state .doc_comment_start,
                else => break :state .slash,
            }
        },

        .doc_comment_start => {
            self.index += 1;
            switch (src[self.index]) {
                // `///` is documentation, `////` and beyond is just a comment.
                '/' => if (src[self.index + 1] == '/')
                    continue :state .line_comment
                else
                    continue :state .doc_comment,
                else => continue :state .line_comment,
            }
        },

        .line_comment => switch (src[self.index]) {
            0 => {
                if (self.index != src.len) {
                    self.index += 1;
                    continue :state .line_comment;
                }
                // Restart so the newline and eof rules see the pre-comment `prev`.
                start = self.index;
                continue :state .start;
            },
            '\n' => {
                start = self.index;
                continue :state .start;
            },
            else => {
                self.index += 1;
                continue :state .line_comment;
            },
        },

        .doc_comment => switch (src[self.index]) {
            0 => {
                if (self.index == src.len) break :state .doc_comment;
                self.index += 1;
                continue :state .doc_comment;
            },
            '\n' => break :state .doc_comment,
            else => {
                self.index += 1;
                continue :state .doc_comment;
            },
        },

        .eq => break :state self.pairOrSingle('=', .eq_eq, .eq),
        .bang => break :state self.pairOrSingle('=', .bang_eq, .bang),
        .lt => break :state self.pairOrSingle('=', .lt_eq, .lt),
        .gt => break :state self.pairOrSingle('=', .gt_eq, .gt),

        .invalid => {
            @branchHint(.cold);
            self.index += 1;
            switch (src[self.index]) {
                0 => if (self.index == src.len) break :state .invalid else continue :state .invalid,
                ' ', '\t', '\r', '\n' => break :state .invalid,
                'a'...'z', 'A'...'Z', '_', '0'...'9', '"' => break :state .invalid,
                '(', ')', '{', '}', ',', '.', ':', ';' => break :state .invalid,
                '=', '!', '<', '>', '+', '-', '*', '/', '%' => break :state .invalid,
                else => continue :state .invalid,
            }
        },
    };

    self.prev = tag;
    return .{ .tag = tag, .start = start };
}

inline fn singleChar(self: *Tokenizer, tag: Token.Tag) Token.Tag {
    self.index += 1;
    return tag;
}

/// Longest-match for a two-character operator.
inline fn pairOrSingle(
    self: *Tokenizer,
    second: u8,
    if_paired: Token.Tag,
    if_alone: Token.Tag,
) Token.Tag {
    self.index += 1;
    if (self.src[self.index] != second) return if_alone;
    self.index += 1;
    return if_paired;
}

/// The byte just past a token. Fixed-length tags answer from the table, and the four
/// variable-length ones rescan.
pub fn tokenEnd(src: [:0]const u8, tag: Token.Tag, start: u32) u32 {
    const fixed = Token.traits[@intFromEnum(tag)].lexeme_len;
    if (fixed != 0) return start + fixed;
    if (tag == .eof) return start;

    var t: Tokenizer = .{ .src = src, .index = start, .prev = .semi };
    const tok = t.next();
    assert(tok.start == start);
    return t.index;
}

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: u32,
});

pub fn estimatedTokenCount(len: usize) usize {
    return len / 4 + len / 16 + 16;
}

/// Tokenizes a buffer into struct-of-arrays form.
pub fn tokenizeAll(gpa: Allocator, src: [:0]const u8, tokens: *TokenList) Allocator.Error!void {
    try tokens.ensureTotalCapacity(gpa, estimatedTokenCount(src.len));

    var t: Tokenizer = .init(src);
    while (true) {
        const tok = t.next();
        if (tokens.len == tokens.capacity) {
            @branchHint(.cold);
            try tokens.ensureTotalCapacity(gpa, tokens.capacity + tokens.capacity / 2 + 16);
        }
        tokens.appendAssumeCapacity(.{ .tag = tok.tag, .start = tok.start });
        if (tok.tag == .eof) break;
    }
}
