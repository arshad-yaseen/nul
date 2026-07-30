const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Diagnostic = @import("Diagnostic.zig");
const Token = @import("Token.zig");
const Source = @import("Source.zig");
const Tokenizer = @import("Tokenizer.zig");
const string_literal = @import("util/string_literal.zig");

const Node = AST.Node;

const Parse = @This();

const depth_max = 128;
const errors_max = 64;

gpa: Allocator,
/// Backs `errors` and every string in it, so freeing them all is one call.
arena: std.heap.ArenaAllocator,
source: [:0]const u8,
tokens: Tokenizer.TokenList.Slice,
/// The tag column, which the cursor reads on nearly every step.
tags: []const Token.Tag,
/// The `.eof` every token list ends with, which the cursor never passes.
eof_index: Token.Index,
/// Only ever moves forward.
token_index: Token.Index,
nodes: AST.NodeList,
extra: std.ArrayList(u32),
scratch: std.ArrayList(Node.Index),
errors: std.ArrayList(Diagnostic),
depth: u32,
/// Set when the parser gave up. Everything after that point is a consequence.
bailed: bool,

pub fn run(gpa: Allocator, source: [:0]const u8) Allocator.Error!AST {
    assert(source.len <= Source.bytes_max);

    var tokens: Tokenizer.TokenList = .empty;
    errdefer tokens.deinit(gpa);

    try Tokenizer.tokenizeAll(gpa, source, &tokens);
    assert(tokens.len > 0);

    var parse: Parse = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .source = source,
        .tokens = tokens.slice(),
        .tags = tokens.items(.tag),
        .eof_index = @enumFromInt(@as(u32, @intCast(tokens.len - 1))),
        .token_index = .first,
        .nodes = .empty,
        .extra = .empty,
        .scratch = .empty,
        .errors = .empty,
        .depth = 0,
        .bailed = false,
    };
    defer parse.scratch.deinit(gpa);

    errdefer {
        parse.nodes.deinit(gpa);
        parse.extra.deinit(gpa);
        parse.arena.deinit();
    }

    try parse.nodes.ensureTotalCapacity(gpa, @divFloor(source.len, 8) + 8);
    try parse.extra.ensureTotalCapacity(gpa, @divFloor(source.len, 16) + 8);

    try parse.parseRoot();
    assert(parse.nodes.len > 0);
    assert(parse.scratch.items.len == 0);

    const extra = try parse.extra.toOwnedSlice(gpa);
    errdefer gpa.free(extra);

    const errors = try parse.errors.toOwnedSlice(parse.arena.allocator());

    return .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parse.nodes.toOwnedSlice(),
        .extra = extra,
        .errors = errors,
        .error_text = parse.arena.state,
    };
}

/// The tag `ahead` tokens past the cursor, or `.eof` past the end.
fn peek(self: *const Parse, ahead: u32) Token.Tag {
    assert(ahead <= 1);
    const index = self.token_index.after(ahead).int();
    if (index < self.tags.len) return self.tags[index];
    return .eof;
}

/// The tag under the cursor.
fn current(self: *const Parse) Token.Tag {
    assert(self.token_index.int() < self.tags.len);
    return self.peek(0);
}

fn at(self: *const Parse, expected: Token.Tag) bool {
    assert(self.token_index.int() <= self.eof_index.int());
    return self.current() == expected;
}

fn eof(self: *const Parse) bool {
    assert(self.eof_index.int() < self.tags.len);
    return self.token_index.int() >= self.eof_index.int();
}

/// Stops at the `.eof`, so the cursor always names a token that exists.
fn nextToken(self: *Parse) Token.Index {
    assert(self.token_index.int() <= self.eof_index.int());

    const consumed = self.token_index;
    if (self.eof()) return consumed;

    self.token_index = self.token_index.after(1);
    assert(self.token_index.int() <= self.eof_index.int());
    return consumed;
}

fn eatToken(self: *Parse, expected: Token.Tag) ?Token.Index {
    assert(expected != .eof);
    return if (self.at(expected)) self.nextToken() else null;
}

fn ensureProgress(self: *Parse, before: Token.Index) void {
    assert(self.token_index.int() >= before.int());

    if (self.token_index == before) _ = self.nextToken();

    if (self.eof() == false) assert(self.token_index.int() > before.int());
}

fn spanOf(self: *const Parse, index: Token.Index) Diagnostic.Span {
    const start = self.tokens.items(.start)[index.int()];
    const end = Tokenizer.tokenEnd(self.source, self.tags[index.int()], start);
    return .{ .start = start, .end = @min(end, @as(u32, @intCast(self.source.len))) };
}

fn here(self: *const Parse) Diagnostic.Span {
    assert(self.token_index.int() <= self.eof_index.int());
    return self.spanOf(self.token_index);
}

/// From `from` to the last token consumed, so exactly what was just parsed.
fn spanSince(self: *const Parse, from: Token.Index) Diagnostic.Span {
    assert(from.int() <= self.token_index.int());
    const last = if (self.token_index.int() > from.int()) self.token_index.before(1) else from;
    return .{ .start = self.spanOf(from).start, .end = self.spanOf(last).end };
}

fn fmt(self: *Parse, comptime template: []const u8, args: anytype) Allocator.Error![]const u8 {
    comptime assert(template.len > 0);
    return std.fmt.allocPrint(self.arena.allocator(), template, args);
}

fn err(self: *Parse, diagnostic: Diagnostic) Allocator.Error!void {
    @branchHint(.cold);
    assert(diagnostic.message.len > 0);
    assert(diagnostic.span.start <= diagnostic.span.end);

    if (self.bailed) return;
    try self.errors.append(self.arena.allocator(), diagnostic);
    if (self.errors.items.len == errors_max) self.stop();
}

/// Steps over whatever is left of a statement, so one mistake reports once.
fn skipToEndOfStatement(self: *Parse) void {
    assert(self.token_index.int() <= self.eof_index.int());

    while (self.eof() == false and self.at(.semi) == false and self.at(.r_brace) == false) {
        self.token_index = self.token_index.after(1);
    }
    _ = self.eatToken(.semi);

    assert(self.token_index.int() <= self.eof_index.int());
}

/// Unwind without reading further.
fn stop(self: *Parse) void {
    @branchHint(.cold);
    assert(self.bailed == false);

    self.bailed = true;
    self.token_index = self.eof_index;
    assert(self.eof());
}

fn errExpected(self: *Parse, code: Diagnostic.Code, what: []const u8) Allocator.Error!void {
    @branchHint(.cold);
    assert(what.len > 0);
    try self.err(.{
        .code = code,
        .span = self.here(),
        .message = try self.fmt("expected {s}, found {s}", .{ what, self.current().symbol() }),
        .label = try self.fmt("expected {s}", .{what}),
    });
}

fn expectToken(self: *Parse, expected: Token.Tag) Allocator.Error!void {
    assert(expected != .eof);
    if (self.eatToken(expected) == null) try self.errExpected(.expected_token, expected.symbol());
}

fn expectClosing(self: *Parse, closer: Token.Tag, opener: ?Token.Index) Allocator.Error!void {
    assert(closer.lexeme() != null);
    if (self.eatToken(closer) != null) return;
    const open = opener orelse return self.errExpected(.expected_token, closer.symbol());
    const opened = self.tags[open.int()].symbol();
    const found = self.current().symbol();

    try self.err(.{
        .code = .expected_token,
        .span = self.here(),
        .message = try self.fmt("expected {s}, found {s}", .{ closer.symbol(), found }),
        .label = try self.fmt("expected {s}", .{closer.symbol()}),
        .notes = try self.arena.allocator().dupe(Diagnostic.Note, &.{.{
            .message = try self.fmt("to close the {s} opened here", .{opened}),
            .span = self.spanOf(open),
        }}),
    });
}

fn expectEndOfStatement(self: *Parse) Allocator.Error!void {
    const found = self.current().symbol();
    switch (self.current()) {
        .semi => self.token_index = self.token_index.after(1),
        // a block or the file itself can end a statement too
        .r_brace, .eof => {},
        else => {
            try self.err(.{
                .code = .expected_token,
                .span = self.here(),
                .message = try self.fmt("expected the end of a statement, found {s}", .{found}),
                .label = "unexpected here",
                .help = "one statement per line",
            });
            self.skipToEndOfStatement();
        },
    }
}

fn tooDeep(self: *Parse) Allocator.Error!Node.Index {
    @branchHint(.cold);
    assert(self.depth <= depth_max);
    try self.err(.{
        .code = .nesting_too_deep,
        .span = self.here(),
        .message = try self.fmt("this nests more than {d} levels deep", .{depth_max}),
        .label = "too deep",
        .help = "the rest of the file was not read",
    });
    const node = try self.hole();
    self.stop();
    return node;
}

fn addNode(self: *Parse, node: Node) Allocator.Error!Node.Index {
    assert(node.main_token.int() < self.tags.len);
    if (self.nodes.len >= std.math.maxInt(u32)) return error.OutOfMemory;

    const index: Node.Index = @enumFromInt(@as(u32, @intCast(self.nodes.len)));
    try self.nodes.append(self.gpa, node);

    assert(self.nodes.len == index.int() + 1);
    return index;
}

fn addLeaf(self: *Parse, node_tag: Node.Tag) Allocator.Error!Node.Index {
    assert(self.eof() == false or self.current() == .eof);
    const token = self.nextToken();
    return self.addNode(.{ .tag = node_tag, .main_token = token, .data = .{ .none = {} } });
}

fn addPair(
    self: *Parse,
    node_tag: Node.Tag,
    main_token: Token.Index,
    lhs: Node.Index,
    rhs: Node.Index,
) Allocator.Error!Node.Index {
    assert(lhs.int() < self.nodes.len);
    assert(rhs.int() < self.nodes.len);
    return self.addNode(.{
        .tag = node_tag,
        .main_token = main_token,
        .data = .{ .node_and_node = .{ lhs, rhs } },
    });
}

fn hole(self: *Parse) Allocator.Error!Node.Index {
    @branchHint(.cold);
    assert(self.token_index.int() <= self.eof_index.int());
    return self.addNode(.{ .tag = .err, .main_token = self.token_index, .data = .{ .none = {} } });
}

/// A hole over a token that can be part of nothing, stepping past it so the
/// caller's loop is guaranteed to move.
fn skip(self: *Parse) Allocator.Error!Node.Index {
    @branchHint(.cold);

    const before = self.token_index;
    const node = try self.hole();
    _ = self.nextToken();

    if (self.eof() == false) assert(self.token_index.int() > before.int());
    return node;
}

/// Every append below keeps the length inside a `u32`, so this cast is bounded
/// by the appends themselves.
fn extraStart(self: *const Parse) AST.ExtraIndex {
    assert(self.extra.items.len < std.math.maxInt(u32));
    return @enumFromInt(@as(u32, @intCast(self.extra.items.len)));
}

fn extraWord(self: *Parse, word: u32) Allocator.Error!void {
    if (self.extra.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;

    const before = self.extra.items.len;
    try self.extra.append(self.gpa, word);

    assert(self.extra.items.len == before + 1);
    assert(self.extra.items[before] == word);
}

fn extraNode(self: *Parse, node: Node.Index) Allocator.Error!void {
    assert(node.int() < self.nodes.len);
    try self.extraWord(@intFromEnum(node));
}

fn extraOpt(self: *Parse, node: Node.OptionalIndex) Allocator.Error!void {
    if (node.unwrap()) |present| assert(present.int() < self.nodes.len);
    try self.extraWord(@intFromEnum(node));
}

fn extraList(self: *Parse, items: []const Node.Index) Allocator.Error!void {
    // one item per node at most, which `addNode` keeps inside a `u32`
    assert(items.len <= self.nodes.len);
    try self.extraWord(@intCast(items.len));

    if (self.extra.items.len + items.len > std.math.maxInt(u32)) return error.OutOfMemory;
    try self.extra.ensureUnusedCapacity(self.gpa, items.len);
    self.extra.appendSliceAssumeCapacity(@ptrCast(items));
}

const TokenSet = std.EnumSet(Token.Tag);

const starts_expr = TokenSet.initMany(&.{
    .ident,     .number,  .str,      .kw_true,     .kw_false,
    .kw_null,   .l_paren, .dot,      .minus,       .bang,
    .ampersand, .kw_try,  .kw_error, .str_escaped, .unterminated_str,
    .invalid,
});

const starts_stmt = starts_expr.unionWith(TokenSet.initMany(&.{
    .kw_let,   .kw_var,      .kw_if,     .kw_while,
    .kw_break, .kw_continue, .kw_return, .kw_defer,
}));

const starts_type = TokenSet.initMany(&.{ .ident, .star, .question, .bang });

const starts_name = TokenSet.initOne(.ident);

const starts_decl = TokenSet.initMany(&.{
    .kw_pub, .kw_use, .kw_struct, .kw_type, .kw_fn, .kw_let, .kw_var,
});

const ends_list = starts_decl.unionWith(TokenSet.initMany(&.{ .l_brace, .r_brace, .semi }));

/// Every bracketed, comma-separated list in the grammar. Type parameters, value
/// parameters, call arguments, type arguments, and struct literal fields are one
/// function because they recover the same way.
const List = struct {
    /// What one element is. Each lands in `scratch`.
    item: *const fn (*Parse) Allocator.Error!Node.Index,
    starts: TokenSet,
    closer: Token.Tag,
    /// Null when the opening bracket was itself missing.
    opener: ?Token.Index,
    code: Diagnostic.Code,
    /// Named in "expected _, found ...".
    expected: []const u8,
};

fn parseList(self: *Parse, list: List) Allocator.Error!void {
    assert(self.depth <= depth_max);
    assert(list.expected.len > 0);

    while (self.at(list.closer) == false and self.eof() == false) {
        const before = self.token_index;

        if (list.starts.contains(self.current())) {
            try self.scratch.append(self.gpa, try list.item(self));
        } else {
            if (ends_list.contains(self.current())) break;
            try self.errExpected(list.code, list.expected);
            try self.scratch.append(self.gpa, try self.skip());
        }

        self.ensureProgress(before);
        if (self.eatToken(.comma) == null) break;
    }
    try self.expectClosing(list.closer, list.opener);
}

// declarations

fn parseRoot(self: *Parse) Allocator.Error!void {
    assert(self.depth <= depth_max);
    assert(self.nodes.len == 0);
    const root = try self.addNode(.{ .tag = .root, .main_token = .first, .data = .{ .none = {} } });
    assert(root == .root);

    const top = self.scratch.items.len;
    defer {
        assert(self.scratch.items.len >= top);
        self.scratch.shrinkRetainingCapacity(top);
    }

    while (self.eof() == false) {
        const before = self.token_index;
        switch (self.current()) {
            .semi, .doc_comment, .file_doc_comment => self.token_index = self.token_index.after(1),
            else => try self.scratch.append(self.gpa, try self.parseDecl()),
        }
        self.ensureProgress(before);
    }

    assert(self.eof());
    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..]);
    self.nodes.items(.data)[Node.Index.root.int()] = .{ .extra = start };
}

fn parseDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(self.eof() == false);
    _ = self.eatToken(.kw_pub);
    switch (self.current()) {
        .kw_use => return self.parseUseDecl(),
        .kw_struct => return self.parseStructDecl(),
        .kw_type => return self.parseTypeDecl(),
        .kw_fn => return self.parseFnDecl(),
        .kw_let => return self.parseVarDecl(),
        .kw_var => {
            try self.err(.{
                .code = .var_at_top_level,
                .span = self.here(),
                .message = "a top-level binding cannot be 'var'",
                .label = "not allowed here",
                .help = "top-level bindings are 'let', and hold a value the compiler can work out",
            });
            return self.parseVarDecl();
        },
        else => {
            const found = self.current().symbol();
            try self.err(.{
                .code = .expected_declaration,
                .span = self.here(),
                .message = try self.fmt("expected a declaration, found {s}", .{found}),
                .label = "not a declaration",
                .help = "a file holds 'use', 'struct', 'type', 'fn', and 'let'",
            });
            return self.skip();
        },
    }
}

fn parseUseDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_use));
    const use_token = self.nextToken();
    const path = try self.parsePath();
    try self.expectEndOfStatement();
    const node = try self.addNode(.{
        .tag = .use_decl,
        .main_token = use_token,
        .data = .{ .node = path },
    });
    assert(self.nodes.items(.tag)[node.int()] == .use_decl);
    return node;
}

/// A dotted name, either an import path or the head of a type.
fn parsePath(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(self.eof() == false or self.current() == .eof);
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_token, Token.Tag.ident.symbol());
        return self.hole();
    }
    var node = try self.addLeaf(.ident);
    while (self.at(.dot)) {
        const dot = self.nextToken();
        if (self.at(.ident) == false) {
            try self.errExpected(.expected_token, Token.Tag.ident.symbol());
            return self.hole();
        }
        _ = self.nextToken();
        node = try self.addNode(.{
            .tag = .field_access,
            .main_token = dot,
            .data = .{ .node = node },
        });
    }
    return node;
}

fn parseStructDecl(self: *Parse) Allocator.Error!Node.Index {
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_struct));
    const struct_token = self.nextToken();
    try self.expectToken(.ident);

    const top = self.scratch.items.len;
    defer {
        assert(self.scratch.items.len >= top);
        self.scratch.shrinkRetainingCapacity(top);
    }

    try self.parseTypeParams();
    const members_start = self.scratch.items.len;

    const lbrace = self.eatToken(.l_brace);
    if (lbrace == null) try self.errExpected(.expected_token, Token.Tag.l_brace.symbol());

    while (self.at(.r_brace) == false and self.eof() == false) {
        const before = self.token_index;
        if (self.at(.semi) or self.at(.doc_comment) or self.at(.file_doc_comment)) {
            self.token_index = self.token_index.after(1);
        } else if (self.at(.ident)) {
            try self.scratch.append(self.gpa, try self.parseField());
        } else if (self.at(.kw_fn) or self.at(.kw_pub)) {
            _ = self.eatToken(.kw_pub);
            if (self.at(.kw_fn)) {
                try self.scratch.append(self.gpa, try self.parseFnDecl());
            } else {
                // a `pub` inside a struct body can only introduce a function
                try self.errExpected(.expected_struct_member, "a function after 'pub'");
                try self.scratch.append(self.gpa, try self.hole());
                self.skipToEndOfStatement();
            }
        } else if (starts_decl.contains(self.current())) {
            break;
        } else {
            try self.errExpected(.expected_struct_member, "a field or a function");
            try self.scratch.append(self.gpa, try self.skip());
        }
        self.ensureProgress(before);
    }
    try self.expectClosing(.r_brace, lbrace);

    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..members_start]);
    try self.extraList(self.scratch.items[members_start..]);
    const node = try self.addNode(.{
        .tag = .struct_decl,
        .main_token = struct_token,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .struct_decl);
    return node;
}

fn parseTypeDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_type));
    const type_token = self.nextToken();
    try self.expectToken(.ident);
    try self.expectToken(.eq);
    const aliased = try self.parseType();
    try self.expectEndOfStatement();
    const node = try self.addNode(.{
        .tag = .type_decl,
        .main_token = type_token,
        .data = .{ .node = aliased },
    });
    assert(self.nodes.items(.tag)[node.int()] == .type_decl);
    return node;
}

fn parseFnDecl(self: *Parse) Allocator.Error!Node.Index {
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_fn));
    const fn_token = self.nextToken();
    try self.expectToken(.ident);

    const top = self.scratch.items.len;
    defer {
        assert(self.scratch.items.len >= top);
        self.scratch.shrinkRetainingCapacity(top);
    }

    try self.parseTypeParams();
    const params_start = self.scratch.items.len;

    const lparen = self.eatToken(.l_paren);
    if (lparen == null) try self.errExpected(.expected_token, Token.Tag.l_paren.symbol());
    try self.parseList(.{
        .item = parseParam,
        .starts = starts_name,
        .closer = .r_paren,
        .opener = lparen,
        .code = .expected_parameter,
        .expected = "a parameter",
    });

    // nothing between the parameters and the body means it returns nothing
    const return_type: Node.OptionalIndex = if (starts_type.contains(self.current()))
        (try self.parseType()).toOptional()
    else
        .none;

    const body = if (self.eatToken(.eq) != null) body: {
        const value = try self.parseExpr();
        try self.expectEndOfStatement();
        break :body value;
    } else try self.parseBlock();

    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..params_start]);
    try self.extraList(self.scratch.items[params_start..]);
    try self.extraOpt(return_type);
    try self.extraNode(body);
    const node = try self.addNode(.{
        .tag = .fn_decl,
        .main_token = fn_token,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .fn_decl);
    return node;
}

fn parseTypeParams(self: *Parse) Allocator.Error!void {
    assert(self.depth <= depth_max);
    assert(self.scratch.items.len < self.nodes.len + 1);
    const lbracket = self.eatToken(.l_bracket) orelse return;
    try self.parseList(.{
        .item = parseTypeParam,
        .starts = starts_name,
        .closer = .r_bracket,
        .opener = lbracket,
        .code = .expected_parameter,
        .expected = "a type parameter",
    });
}

fn parseTypeParam(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.ident));
    const name = self.nextToken();
    return self.addNode(.{ .tag = .type_param, .main_token = name, .data = .{ .none = {} } });
}

fn parseParam(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.ident));
    const name = self.nextToken();
    try self.expectToken(.colon);
    const type_expr = try self.parseType();
    return self.addNode(.{ .tag = .param, .main_token = name, .data = .{ .node = type_expr } });
}

fn parseField(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.ident));
    const name = self.nextToken();
    try self.expectToken(.colon);
    const type_expr = try self.parseType();
    try self.expectEndOfStatement();
    return self.addNode(.{ .tag = .field, .main_token = name, .data = .{ .node = type_expr } });
}

// statements

fn parseBlock(self: *Parse) Allocator.Error!Node.Index {
    if (self.at(.l_brace) == false) {
        try self.errExpected(.expected_token, Token.Tag.l_brace.symbol());
        return self.hole();
    }
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;
    assert(self.depth <= depth_max);

    const lbrace = self.nextToken();
    const top = self.scratch.items.len;
    defer {
        assert(self.scratch.items.len >= top);
        self.scratch.shrinkRetainingCapacity(top);
    }

    while (self.at(.r_brace) == false and self.eof() == false) {
        const before = self.token_index;
        if (self.at(.semi) or self.at(.doc_comment) or self.at(.file_doc_comment)) {
            self.token_index = self.token_index.after(1);
        } else if (self.at(.kw_else)) {
            try self.scratch.append(self.gpa, try self.parseStrayElse());
        } else if (starts_stmt.contains(self.current())) {
            try self.scratch.append(self.gpa, try self.parseStatement());
        } else if (starts_decl.contains(self.current())) {
            break;
        } else {
            try self.errExpected(.expected_statement, "a statement");
            try self.scratch.append(self.gpa, try self.skip());
        }
        self.ensureProgress(before);
    }
    try self.expectClosing(.r_brace, lbrace);

    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..]);
    const node = try self.addNode(.{
        .tag = .block,
        .main_token = lbrace,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .block);
    return node;
}

fn parseStatement(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(starts_stmt.contains(self.current()));
    switch (self.current()) {
        .kw_let, .kw_var => return self.parseVarDecl(),
        .kw_if => return self.parseIf(),
        .kw_while => return self.parseWhile(),
        .kw_break, .kw_continue => {
            const stmt_tag: Node.Tag = if (self.at(.kw_break)) .break_stmt else .continue_stmt;
            const keyword = self.nextToken();
            try self.expectEndOfStatement();
            return self.addNode(.{
                .tag = stmt_tag,
                .main_token = keyword,
                .data = .{ .none = {} },
            });
        },
        .kw_return => {
            const return_token = self.nextToken();
            const operand: Node.OptionalIndex = if (starts_expr.contains(self.current()))
                (try self.parseExpr()).toOptional()
            else
                .none;
            try self.expectEndOfStatement();
            return self.addNode(.{
                .tag = .return_stmt,
                .main_token = return_token,
                .data = .{ .opt_node = operand },
            });
        },
        .kw_defer => {
            const defer_token = self.nextToken();
            const expr = try self.parseExpr();
            try self.expectEndOfStatement();
            return self.addNode(.{
                .tag = .defer_stmt,
                .main_token = defer_token,
                .data = .{ .node = expr },
            });
        },
        else => return self.parseExprStatement(),
    }
}

/// The likeliest cause is the newline before it, which ended the `if`. Its arm is
/// read anyway, so the mistake reports once rather than once per token inside it.
fn parseStrayElse(self: *Parse) Allocator.Error!Node.Index {
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_else));
    try self.err(.{
        .code = .stray_else,
        .span = self.here(),
        .message = "'else' has no 'if' to belong to",
        .label = "no 'if' here",
        .help = "an 'else' sits on the same line as the '}' that closes its 'if'",
    });
    _ = self.nextToken();
    return if (self.at(.kw_if)) self.parseIf() else self.parseBlock();
}

/// No parentheses, and braces are mandatory, so no arm can dangle.
fn parseIf(self: *Parse) Allocator.Error!Node.Index {
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_if));
    // an `else if` chain recurses with no block in between, so it guards itself
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;
    assert(self.depth <= depth_max);

    const if_token = self.nextToken();
    const cond = try self.parseExpr();
    const capture = try self.parseCapture();
    const then_block = try self.parseBlock();
    const else_node: Node.OptionalIndex = if (self.eatToken(.kw_else) != null)
        // `else if` chains as a nested `if_stmt`, so one shape covers every arm
        (if (self.at(.kw_if)) try self.parseIf() else try self.parseBlock()).toOptional()
    else
        .none;

    const start = self.extraStart();
    try self.extraNode(cond);
    try self.extraOpt(capture);
    try self.extraNode(then_block);
    try self.extraOpt(else_node);
    const node = try self.addNode(.{
        .tag = .if_stmt,
        .main_token = if_token,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .if_stmt);
    return node;
}

/// `|v|`, naming what an optional held or what error a `catch` caught.
fn parseCapture(self: *Parse) Allocator.Error!Node.OptionalIndex {
    assert(self.depth <= depth_max);
    assert(self.token_index.int() <= self.eof_index.int());
    if (self.eatToken(.pipe) == null) return .none;
    assert(self.tags[self.token_index.before(1).int()] == .pipe);
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_token, Token.Tag.ident.symbol());
        return (try self.hole()).toOptional();
    }
    const name = self.nextToken();
    try self.expectToken(.pipe);
    const node = try self.addNode(.{
        .tag = .capture,
        .main_token = name,
        .data = .{ .none = {} },
    });
    return node.toOptional();
}

fn parseWhile(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_while));
    const while_token = self.nextToken();
    const cond: Node.OptionalIndex = if (self.at(.l_brace))
        .none
    else
        (try self.parseExpr()).toOptional();
    const capture = try self.parseCapture();
    const body = try self.parseBlock();

    const start = self.extraStart();
    try self.extraOpt(cond);
    try self.extraOpt(capture);
    try self.extraNode(body);
    const node = try self.addNode(.{
        .tag = .while_stmt,
        .main_token = while_token,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .while_stmt);
    return node;
}

fn parseVarDecl(self: *Parse) Allocator.Error!Node.Index {
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    const keyword = self.nextToken();
    // a report can reach `errors_max` and jump the cursor to the end of file
    if (self.bailed == false) {
        assert(self.tags[keyword.int()] == .kw_let or self.tags[keyword.int()] == .kw_var);
    }
    try self.expectToken(.ident);

    const type_expr: Node.OptionalIndex = if (self.eatToken(.colon) != null)
        (try self.parseType()).toOptional()
    else
        .none;

    try self.expectToken(.eq);
    const init_expr = try self.parseExpr();
    try self.expectEndOfStatement();

    return self.addNode(.{
        .tag = .var_decl,
        .main_token = keyword,
        .data = .{ .opt_node_and_node = .{ type_expr, init_expr } },
    });
}

fn parseExprStatement(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const from = self.token_index;

    const lhs = try self.parseExpr();
    assert(lhs.int() < self.nodes.len);
    if (self.at(.eq) == false) {
        try self.expectEndOfStatement();
        return lhs;
    }

    // `1 = x` is a shape error, so it never reaches a checker
    switch (self.nodes.items(.tag)[@intFromEnum(lhs)]) {
        .ident, .field_access, .err => {},
        else => try self.err(.{
            .code = .invalid_assign_target,
            .span = self.spanSince(from),
            .message = "this cannot be assigned to",
            .label = "not a place",
            .help = "the left of '=' is a name, or a field reached from one",
        }),
    }

    const eq = self.nextToken();
    const rhs = try self.parseExpr();
    try self.expectEndOfStatement();
    return self.addPair(.assign, eq, lhs, rhs);
}

// expressions

fn parseExpr(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(self.depth <= depth_max);
    return self.parseExprPrec(1);
}

fn parseExprPrec(self: *Parse, min_prec: u8) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(min_prec > 0);
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;
    assert(self.depth <= depth_max);

    var node = try self.parsePrefixExpr();
    var banned_prec: u8 = 0;

    while (true) {
        const info = AST.oper_table[@intFromEnum(self.current())];
        if (info.prec < min_prec) break;
        if (info.prec == banned_prec) {
            try self.err(.{
                .code = .chained_comparison,
                .span = self.here(),
                .message = "comparisons cannot be chained",
                .label = "a second comparison",
                .help = "write it as two comparisons joined with 'and'",
            });
        }

        const op_tag = self.current();
        const op_token = self.nextToken();
        const min = if (info.assoc == .right) info.prec else info.prec + 1;

        node = switch (op_tag) {
            .kw_catch => try self.parseCatchTail(node, op_token, min),
            .kw_orelse => orelse_expr: {
                // `a orelse { }`
                const rhs = if (self.at(.l_brace))
                    try self.parseBlock()
                else
                    try self.parseExprPrec(min);
                break :orelse_expr try self.addPair(.orelse_expr, op_token, node, rhs);
            },
            else => try self.addPair(.binary, op_token, node, try self.parseExprPrec(min)),
        };

        banned_prec = if (info.assoc == .none) info.prec else 0;
    }
    return node;
}

/// `a catch b` and `a catch |err| { }`.
fn parseCatchTail(
    self: *Parse,
    lhs: Node.Index,
    catch_token: Token.Index,
    min_prec: u8,
) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(lhs.int() < self.nodes.len);
    assert(self.tags[catch_token.int()] == .kw_catch);
    const capture = try self.parseCapture();
    const rhs = if (self.at(.l_brace)) try self.parseBlock() else try self.parseExprPrec(min_prec);

    const start = self.extraStart();
    try self.extraNode(lhs);
    try self.extraOpt(capture);
    try self.extraNode(rhs);
    const node = try self.addNode(.{
        .tag = .catch_expr,
        .main_token = catch_token,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .catch_expr);
    return node;
}

fn parsePrefixExpr(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(self.depth <= depth_max);
    const node_tag: Node.Tag = switch (self.current()) {
        .kw_try => .try_expr,
        .minus, .bang, .ampersand => .unary,
        else => return self.parseSuffixExpr(),
    };
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;
    assert(self.depth <= depth_max);

    const op_token = self.nextToken();
    const operand = try self.parsePrefixExpr();
    return self.addNode(.{ .tag = node_tag, .main_token = op_token, .data = .{ .node = operand } });
}

fn parseSuffixExpr(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    var node = try self.parsePrimaryExpr();
    assert(node.int() < self.nodes.len);
    // each suffix wraps the one before it, so a chain is tree depth even though
    // it is written as a loop, and every later walk descends it
    var suffixes: u32 = 0;

    while (true) {
        if (suffixes >= depth_max) return self.tooDeep();
        suffixes += 1;
        switch (self.current()) {
            .l_paren => node = try self.parseCall(node),
            .l_bracket => node = try self.parseInstance(node),
            .dot => {
                const dot = self.nextToken();
                if (self.at(.ident) == false) {
                    try self.errExpected(.expected_token, Token.Tag.ident.symbol());
                    return self.hole();
                }
                _ = self.nextToken();
                node = try self.addNode(.{
                    .tag = .field_access,
                    .main_token = dot,
                    .data = .{ .node = node },
                });
            },
            else => return node,
        }
    }
}

fn parseCall(self: *Parse, callee: Node.Index) Allocator.Error!Node.Index {
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.l_paren));
    assert(callee.int() < self.nodes.len);
    const lparen = self.nextToken();
    const top = self.scratch.items.len;
    defer {
        assert(self.scratch.items.len >= top);
        self.scratch.shrinkRetainingCapacity(top);
    }

    try self.parseList(.{
        .item = parseExpr,
        .starts = starts_expr,
        .closer = .r_paren,
        .opener = lparen,
        .code = .expected_expression,
        .expected = "an argument",
    });

    const start = self.extraStart();
    try self.extraNode(callee);
    try self.extraList(self.scratch.items[top..]);
    const node = try self.addNode(.{
        .tag = .call,
        .main_token = lparen,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .call);
    return node;
}

/// `Box[i64]` in a type and `create[Node]` in a call are the same thing, so they
/// are the same node.
fn parseInstance(self: *Parse, base: Node.Index) Allocator.Error!Node.Index {
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.l_bracket));
    assert(base.int() < self.nodes.len);
    const lbracket = self.nextToken();
    const top = self.scratch.items.len;
    defer {
        assert(self.scratch.items.len >= top);
        self.scratch.shrinkRetainingCapacity(top);
    }

    try self.parseList(.{
        .item = parseType,
        .starts = starts_type,
        .closer = .r_bracket,
        .opener = lbracket,
        .code = .expected_type,
        .expected = "a type argument",
    });

    const start = self.extraStart();
    try self.extraNode(base);
    try self.extraList(self.scratch.items[top..]);
    const node = try self.addNode(.{
        .tag = .instance,
        .main_token = lbracket,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .instance);
    return node;
}

fn parsePrimaryExpr(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    switch (self.current()) {
        .ident => return self.addLeaf(.ident),
        .number => return self.addLeaf(.number_literal),
        .kw_true, .kw_false => return self.addLeaf(.bool_literal),
        .kw_null => return self.addLeaf(.null_literal),
        .str => return self.addLeaf(.str_literal),
        .str_escaped => return self.parseEscapedString(),
        .kw_error => return self.parseErrorValue(),
        .dot => return self.parseStructLiteral(),
        .l_paren => {
            const lparen = self.nextToken();
            const inner = try self.parseExpr();
            try self.expectClosing(.r_paren, lparen);
            return self.addNode(.{
                .tag = .grouped,
                .main_token = lparen,
                .data = .{ .node = inner },
            });
        },
        .unterminated_str => {
            try self.err(.{
                .code = .unterminated_string,
                .span = self.here(),
                .message = "this string is never closed",
                .label = "no closing '\"' before the end of the line",
                .help = "a string literal stays on one line",
            });
            return self.skip();
        },
        .invalid => {
            try self.err(.{
                .code = .invalid_bytes,
                .span = self.here(),
                .message = "these bytes are not part of the language",
                .label = "not readable as anything",
            });
            return self.skip();
        },
        else => {
            try self.errExpected(.expected_expression, "an expression");
            return self.hole();
        },
    }
}

fn parseEscapedString(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.str_escaped));

    const token = self.nextToken();
    const span = self.spanOf(token);
    if (string_literal.badEscape(self.source[span.start..span.end])) |offset| {
        const start = span.start + offset;
        // the closing quote is always past the backslash, so this stays in the token
        const escaped = if (start + 1 < self.source.len) self.source[start + 1] else 0;
        try self.err(.{
            .code = .invalid_escape,
            .span = .{ .start = start, .end = start + 2 },
            .message = if (std.ascii.isPrint(escaped))
                try self.fmt("'\\{c}' is not an escape", .{escaped})
            else
                try self.fmt("'\\x{x:0>2}' is not an escape", .{escaped}),
            .label = "unknown escape",
            .help = "the escapes are " ++ string_literal.escapes,
        });
    }
    return self.addNode(.{ .tag = .str_literal, .main_token = token, .data = .{ .none = {} } });
}

fn parseErrorValue(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.kw_error));
    _ = self.nextToken();
    if (self.at(.dot) == false) {
        try self.errExpected(.expected_token, Token.Tag.dot.symbol());
        return self.hole();
    }
    _ = self.nextToken();
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_token, Token.Tag.ident.symbol());
        return self.hole();
    }
    // `main_token` is the member, so the keyword is two tokens before it
    const name = self.nextToken();
    assert(self.tags[name.before(2).int()] == .kw_error);
    return self.addNode(.{ .tag = .error_value, .main_token = name, .data = .{ .none = {} } });
}

fn parseStructLiteral(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.dot));

    if (self.peek(1) != .l_brace) {
        try self.err(.{
            .code = .expected_expression,
            .span = self.here(),
            .message = "a '.' here begins a struct literal",
            .label = "expected '{' after this",
            .help = "a struct literal is written '.{ field: value }'",
        });
        return self.skip();
    }

    const dot = self.nextToken();
    const lbrace = self.nextToken();
    const top = self.scratch.items.len;
    defer {
        assert(self.scratch.items.len >= top);
        self.scratch.shrinkRetainingCapacity(top);
    }

    try self.parseList(.{
        .item = parseFieldInit,
        .starts = starts_name,
        .closer = .r_brace,
        .opener = lbrace,
        .code = .expected_field_value,
        .expected = "'field: value'",
    });

    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..]);
    const node = try self.addNode(.{
        .tag = .struct_literal,
        .main_token = dot,
        .data = .{ .extra = start },
    });
    assert(self.nodes.items(.tag)[node.int()] == .struct_literal);
    return node;
}

fn parseFieldInit(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    const entry = self.token_index;
    defer assert(self.token_index.int() > entry.int() or self.eof());
    assert(self.at(.ident));
    const name = self.nextToken();
    try self.expectToken(.colon);
    const value = try self.parseExpr();
    return self.addNode(.{
        .tag = .struct_field_init,
        .main_token = name,
        .data = .{ .node = value },
    });
}

// types

fn parseType(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(self.depth <= depth_max);

    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;
    assert(self.depth <= depth_max);

    const node_tag: Node.Tag = switch (self.current()) {
        .star => .pointer_type,
        .question => .optional_type,
        .bang => .error_union_type,
        else => return self.parseTypePath(),
    };

    const op_token = self.nextToken();
    if (node_tag == .pointer_type) _ = self.eatToken(.kw_var);
    const child = try self.parseType();
    return self.addNode(.{ .tag = node_tag, .main_token = op_token, .data = .{ .node = child } });
}

fn parseTypePath(self: *Parse) Allocator.Error!Node.Index {
    assert(self.depth <= depth_max);
    assert(self.depth <= depth_max);
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_type, "a type");
        return self.hole();
    }
    const path = try self.parsePath();
    return if (self.at(.l_bracket)) self.parseInstance(path) else path;
}
