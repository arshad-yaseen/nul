const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const AST = @import("AST.zig");
const Diagnostic = @import("Diagnostic.zig");
const Token = @import("Token.zig");
const Source = @import("Source.zig");
const Tokenizer = @import("Tokenizer.zig");

const Node = AST.Node;

const Parse = @This();

pub const depth_max = 128;
pub const type_params_max = 16;
const errors_max = 64;

gpa: Allocator,
/// Backs `errors` and its strings.
arena: std.heap.ArenaAllocator,
source: [:0]const u8,
tokens: Tokenizer.TokenList.Slice,
/// The column the cursor reads on nearly every step.
tags: []const Token.Tag,
/// The `.eof` the cursor never passes.
eof_index: Token.Index,
/// Only ever moves forward.
token_index: Token.Index,
nodes: std.MultiArrayList(AST.Node),
extra: std.ArrayList(u32),
scratch: std.ArrayList(Node.Index),
errors: std.ArrayList(Diagnostic),
depth: u32,
/// Set when the parser gave up.
bailed: bool,

pub fn run(gpa: Allocator, source: [:0]const u8) Allocator.Error!AST {
    assert(source.len <= Source.bytes_max);

    var tokens: Tokenizer.TokenList = .empty;
    errdefer tokens.deinit(gpa);

    var comments: Tokenizer.CommentList = .empty;
    errdefer comments.deinit(gpa);

    try Tokenizer.tokenizeAll(gpa, source, &tokens, &comments);
    assert(tokens.len > 0);

    var parse: Parse = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .source = source,
        .tokens = tokens.slice(),
        .tags = tokens.items(.tag),
        .eof_index = .from(tokens.len - 1),
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
        .comments = try comments.toOwnedSlice(gpa),
        .nodes = parse.nodes.toOwnedSlice(),
        .extra = extra,
        .errors = errors,
        .error_text = parse.arena.state,
    };
}

/// Or `.eof` past the end.
fn peek(self: *const Parse, ahead: u32) Token.Tag {
    assert(ahead <= 1);
    const index = self.token_index.after(ahead).int();
    if (index < self.tags.len) return self.tags[index];
    return .eof;
}

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

/// Stops at the `.eof`, so the cursor always names a token.
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

/// From `from` to the last token consumed.
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

/// Over the rest of an item, so one mistake reports once.
fn skipToTerminator(self: *Parse, closer: Token.Tag) void {
    assert(self.token_index.int() <= self.eof_index.int());

    while (self.eof() == false and self.at(closer) == false and
        self.at(.semi) == false and self.at(.comma) == false and self.at(.r_brace) == false)
    {
        self.token_index = self.token_index.after(1);
    }
    _ = self.eatTerminators();

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

fn errExpected(self: *Parse, code: Diagnostic.Code, what: []const u8, help: ?[]const u8) Allocator.Error!void {
    @branchHint(.cold);
    assert(what.len > 0);
    try self.err(.{
        .code = code,
        .span = self.here(),
        .message = try self.fmt("expected {s}, found {s}", .{ what, self.current().symbol() }),
        .label = try self.fmt("expected {s}", .{what}),
        .help = help,
    });
}

fn expectToken(self: *Parse, expected: Token.Tag) Allocator.Error!void {
    assert(expected != .eof);
    if (self.eatToken(expected) == null) try self.errExpected(.expected_token, expected.symbol(), null);
}

fn expectClosing(self: *Parse, closer: Token.Tag, opener: ?Token.Index) Allocator.Error!void {
    assert(closer.lexeme() != null);
    if (self.eatToken(closer) != null) return;
    const open = opener orelse return self.errExpected(.expected_token, closer.symbol(), null);
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

/// What stood between two items. Only a bare line break leaves doubt.
const Terminator = enum { none, line, comma };

/// An end of line, a ',' and a ';' all end an item, and a run of them ends one.
fn eatTerminators(self: *Parse) Terminator {
    var found: Terminator = .none;
    while (self.at(.semi) or self.at(.comma)) {
        if (self.at(.comma)) found = .comma else if (found == .none) found = .line;
        self.token_index = self.token_index.after(1);
    }
    return found;
}

/// Every item ends the same way, and a bracket ends the last one for free.
fn expectTerminator(self: *Parse, closer: Token.Tag) Allocator.Error!void {
    if (self.eatTerminators() != .none) return;
    switch (self.current()) {
        // a bracket or the file itself also ends an item
        .r_paren, .r_bracket, .r_brace, .eof => return,
        else => {},
    }
    try self.err(.{
        .code = .expected_token,
        .span = self.here(),
        .message = try self.fmt("expected ',' or the end of the line, found {s}", .{
            self.current().symbol(),
        }),
        .label = "unexpected here",
        .help = "one per line, or a ',' between them",
    });
    self.skipToTerminator(closer);
}

/// A line opening with one of these may be continuing the line above.
const continues_line = TokenSet.initMany(&.{ .minus, .ampersand, .bang, .l_paren });

fn errAmbiguousLine(self: *Parse) Allocator.Error!void {
    @branchHint(.cold);
    try self.err(.{
        .code = .ambiguous_line,
        .span = self.here(),
        .message = try self.fmt("this line opens with {s}, which may continue the line above", .{
            self.current().symbol(),
        }),
        .label = "unclear what this belongs to",
        .help = "move it up to continue that line, or write ',' before it to start a new one",
    });
}

fn tooDeep(self: *Parse) Allocator.Error!Node.Index {
    @branchHint(.cold);
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

    const index: Node.Index = .from(self.nodes.len);
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

/// A hole over a token nothing can use, stepping past it so the caller moves.
fn skip(self: *Parse) Allocator.Error!Node.Index {
    @branchHint(.cold);

    const before = self.token_index;
    const node = try self.hole();
    _ = self.nextToken();

    if (self.eof() == false) assert(self.token_index.int() > before.int());
    return node;
}

/// Bounded by the appends below, which keep the length inside a `u32`.
fn extraStart(self: *const Parse) AST.ExtraIndex {
    assert(self.extra.items.len < std.math.maxInt(u32));
    return .from(self.extra.items.len);
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
    // one item per node at most
    assert(items.len <= self.nodes.len);
    try self.extraWord(@intCast(items.len));

    if (self.extra.items.len + items.len > std.math.maxInt(u32)) return error.OutOfMemory;
    try self.extra.ensureUnusedCapacity(self.gpa, items.len);
    self.extra.appendSliceAssumeCapacity(@ptrCast(items));
}

const TokenSet = std.EnumSet(Token.Tag);

const starts_expr = TokenSet.initMany(&.{
    .ident,   .number,    .kw_true,   .kw_false,
    .kw_null, .l_paren,   .dot,       .minus,
    .bang,    .kw_try,    .ampersand, .invalid,
    .kw_if,   .kw_return, .kw_break,  .kw_continue,
});

const starts_stmt = starts_expr.unionWith(TokenSet.initMany(&.{
    .kw_let, .kw_var, .kw_while, .kw_defer, .kw_else,
}));

const starts_member = TokenSet.initMany(&.{ .ident, .kw_fn, .kw_pub });

const starts_type = TokenSet.initMany(&.{ .ident, .star, .question, .bang });

const starts_name = TokenSet.initOne(.ident);

const starts_decl = TokenSet.initMany(&.{
    .kw_pub,   .kw_use, .kw_struct, .kw_type,
    .kw_error, .kw_fn,  .kw_let,    .kw_var,
});

const ends_list = starts_decl.unionWith(TokenSet.initMany(&.{ .l_brace, .r_brace, .semi }));

/// Every list: a file, a block, a struct body, and everything bracketed.
const List = struct {
    /// Each element lands in `scratch`.
    item: *const fn (*Parse) Allocator.Error!Node.Index,
    starts: TokenSet,
    /// `.eof` for the file, which no bracket closes.
    closer: Token.Tag,
    /// Null when the opening bracket was itself missing.
    opener: ?Token.Index,
    code: Diagnostic.Code,
    /// Named in "expected _, found ...".
    expected: []const u8,
    help: ?[]const u8 = null,
    /// What means this list was never closed. Nothing does, for a file.
    bails: TokenSet = ends_list,
};

fn skipItem(self: *Parse, closer: Token.Tag) Allocator.Error!Node.Index {
    @branchHint(.cold);
    const node = try self.hole();
    while (self.eof() == false) {
        if (self.at(.comma)) break;
        if (self.at(closer)) break;
        if (ends_list.contains(self.current())) break;
        self.token_index = self.token_index.after(1);
    }
    return node;
}

fn parseList(self: *Parse, list: List) Allocator.Error!void {
    assert(list.expected.len > 0);

    var item_end = self.token_index;
    var line_break_only = false;
    while (self.at(list.closer) == false and self.eof() == false) {
        const before = self.token_index;

        if (list.starts.contains(self.current())) {
            if (line_break_only and continues_line.contains(self.current())) {
                try self.errAmbiguousLine();
            }
            try self.scratch.append(self.gpa, try list.item(self));
        } else {
            if (list.bails.contains(self.current())) break;
            try self.errExpected(list.code, list.expected, list.help);
            try self.scratch.append(self.gpa, try self.skipItem(list.closer));
        }

        self.ensureProgress(before);
        item_end = self.token_index;
        const terminator = self.eatTerminators();
        line_break_only = terminator == .line;
        if (terminator == .none) {
            if (self.at(list.closer) or self.eof()) break;
            try self.expectTerminator(list.closer);
        }
    }
    if (list.closer == .eof) return;

    // a list that never closed ran out at the end of its last line
    if (self.at(list.closer) == false and self.tags[item_end.int()] == .semi) {
        self.token_index = item_end;
    }
    try self.expectClosing(list.closer, list.opener);
}

// declarations

fn parseRoot(self: *Parse) Allocator.Error!void {
    assert(self.nodes.len == 0);
    const root = try self.addNode(.{ .tag = .root, .main_token = .first, .data = .{ .none = {} } });
    assert(root == .root);

    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);

    try self.parseList(.{
        .item = parseDecl,
        .starts = starts_decl,
        .closer = .eof,
        .opener = null,
        .code = .expected_declaration,
        .expected = "a declaration",
        .help = "a file holds 'use', 'struct', 'type', 'fn', and 'let'",
        .bails = TokenSet.initEmpty(),
    });

    assert(self.eof());
    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..]);
    self.nodes.items(.data)[Node.Index.root.int()] = .{ .extra = start };
}

fn parseDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.eof() == false);
    _ = self.eatToken(.kw_pub);
    switch (self.current()) {
        .kw_use => return self.parseUseDecl(),
        .kw_struct => return self.parseStructDecl(),
        .kw_type => return self.parseTypeDecl(),
        .kw_error => return self.parseErrorDecl(),
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
        // `pub` with nothing it can introduce
        else => {
            try self.errExpected(.expected_declaration, "a declaration", null);
            return self.skip();
        },
    }
}

fn parseUseDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_use));
    const use_token = self.nextToken();
    const path = try self.parsePath();
    return self.addNode(.{
        .tag = .use_decl,
        .main_token = use_token,
        .data = .{ .node = path },
    });
}

/// `.name` reached from what came before, or null once reported.
fn parseFieldAccess(self: *Parse, base: Node.Index) Allocator.Error!?Node.Index {
    assert(self.at(.dot));
    const dot = self.nextToken();
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_token, Token.Tag.ident.symbol(), null);
        return null;
    }
    _ = self.nextToken();
    return try self.addNode(.{
        .tag = .field_access,
        .main_token = dot,
        .data = .{ .node = base },
    });
}

/// An import path, or the head of a type.
fn parsePath(self: *Parse) Allocator.Error!Node.Index {
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_token, Token.Tag.ident.symbol(), null);
        return self.hole();
    }
    var node = try self.addLeaf(.ident);
    while (self.at(.dot)) node = try self.parseFieldAccess(node) orelse return self.hole();
    return node;
}

fn parseStructDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_struct));
    const struct_token = self.nextToken();
    try self.expectToken(.ident);

    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);

    try self.parseTypeParams();
    const members_start = self.scratch.items.len;

    const lbrace = self.eatToken(.l_brace);
    if (lbrace == null) try self.errExpected(.expected_token, Token.Tag.l_brace.symbol(), null);

    try self.parseList(.{
        .item = parseMember,
        .starts = starts_member,
        .closer = .r_brace,
        .opener = lbrace,
        .code = .expected_struct_member,
        .expected = "a field or a function",
    });

    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..members_start]);
    try self.extraList(self.scratch.items[members_start..]);
    return self.addNode(.{
        .tag = .struct_decl,
        .main_token = struct_token,
        .data = .{ .extra = start },
    });
}

fn parseTypeDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_type));
    const type_token = self.nextToken();
    try self.expectToken(.ident);
    try self.expectToken(.eq);
    const aliased = try self.parseType();
    return self.addNode(.{
        .tag = .type_decl,
        .main_token = type_token,
        .data = .{ .node = aliased },
    });
}

/// `error Name`
fn parseErrorDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_error));

    const error_token = self.nextToken();
    try self.expectToken(.ident);
    return self.addNode(.{
        .tag = .error_decl,
        .main_token = error_token,
        .data = .{ .none = {} },
    });
}

fn parseFnDecl(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_fn));
    const fn_token = self.nextToken();
    try self.expectToken(.ident);

    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);

    try self.parseTypeParams();
    const params_start = self.scratch.items.len;

    const lparen = self.eatToken(.l_paren);
    if (lparen == null) try self.errExpected(.expected_token, Token.Tag.l_paren.symbol(), null);
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

    const body = try self.parseBlock();

    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..params_start]);
    try self.extraList(self.scratch.items[params_start..]);
    try self.extraOpt(return_type);
    try self.extraNode(body);
    return self.addNode(.{
        .tag = .fn_decl,
        .main_token = fn_token,
        .data = .{ .extra = start },
    });
}

fn parseTypeParams(self: *Parse) Allocator.Error!void {
    assert(self.scratch.items.len < self.nodes.len + 1);
    const lbracket = self.eatToken(.l_bracket) orelse return;

    const top = self.scratch.items.len;
    try self.parseList(.{
        .item = parseTypeParam,
        .starts = starts_name,
        .closer = .r_bracket,
        .opener = lbracket,
        .code = .expected_parameter,
        .expected = "a type parameter",
    });

    assert(self.scratch.items.len >= top);
    if (self.scratch.items.len - top > type_params_max) try self.errTypeParams(lbracket, top);
    assert(self.scratch.items.len - top <= type_params_max);
}

fn errTypeParams(self: *Parse, lbracket: Token.Index, top: usize) Allocator.Error!void {
    @branchHint(.cold);
    assert(self.scratch.items.len - top > type_params_max);

    try self.err(.{
        .code = .too_many_type_params,
        .span = self.spanOf(lbracket),
        .message = try self.fmt("this declares more than {d} type parameters", .{type_params_max}),
        .label = "too many",
        .help = "a declaration this generic is asking for a struct of its own",
    });
    self.scratch.shrinkRetainingCapacity(top + type_params_max);
}

fn parseTypeParam(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.ident));
    const name = self.nextToken();
    return self.addNode(.{ .tag = .type_param, .main_token = name, .data = .{ .none = {} } });
}

fn parseParam(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.ident));
    const name = self.nextToken();
    try self.expectToken(.colon);
    const type_expr = try self.parseType();
    return self.addNode(.{ .tag = .param, .main_token = name, .data = .{ .node = type_expr } });
}

fn parseField(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.ident));
    const name = self.nextToken();
    try self.expectToken(.colon);
    const type_expr = try self.parseType();
    return self.addNode(.{ .tag = .field, .main_token = name, .data = .{ .node = type_expr } });
}

/// A struct body holds fields and functions, and `pub` introduces a function.
fn parseMember(self: *Parse) Allocator.Error!Node.Index {
    assert(starts_member.contains(self.current()));
    if (self.at(.ident)) return self.parseField();

    _ = self.eatToken(.kw_pub);
    if (self.at(.kw_fn)) return self.parseFnDecl();
    try self.errExpected(.expected_struct_member, "a function after 'pub'", null);
    return self.hole();
}

// statements

fn parseBlock(self: *Parse) Allocator.Error!Node.Index {
    if (self.at(.l_brace) == false) {
        try self.errExpected(.expected_token, Token.Tag.l_brace.symbol(), null);
        return self.hole();
    }
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;

    const lbrace = self.nextToken();
    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);

    try self.parseList(.{
        .item = parseStatement,
        .starts = starts_stmt,
        .closer = .r_brace,
        .opener = lbrace,
        .code = .expected_statement,
        .expected = "a statement",
    });

    const start = self.extraStart();
    try self.extraList(self.scratch.items[top..]);
    return self.addNode(.{
        .tag = .block,
        .main_token = lbrace,
        .data = .{ .extra = start },
    });
}

fn parseStatement(self: *Parse) Allocator.Error!Node.Index {
    assert(starts_stmt.contains(self.current()));
    switch (self.current()) {
        .kw_let, .kw_var => return self.parseVarDecl(),
        .kw_while => return self.parseWhile(),
        .kw_else => return self.parseStrayElse(),
        .kw_defer => {
            const defer_token = self.nextToken();
            const expr = try self.parseExpr();
            return self.addNode(.{
                .tag = .defer_stmt,
                .main_token = defer_token,
                .data = .{ .node = expr },
            });
        },
        else => return self.parseExprStatement(),
    }
}

/// The likeliest cause is the newline that ended the `if`. The arm is read
/// anyway, so the mistake reports once.
fn parseStrayElse(self: *Parse) Allocator.Error!Node.Index {
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

/// No parentheses, and mandatory braces, so no arm can dangle.
fn parseIf(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_if));
    // an `else if` chain recurses with no block between
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;

    const if_token = self.nextToken();
    const cond = try self.parseExpr();
    const capture = try self.parseCapture();
    const then_block = try self.parseBlock();
    const else_node: Node.OptionalIndex = if (self.eatToken(.kw_else) != null)
        // `else if` nests as an `if_expr`
        (if (self.at(.kw_if)) try self.parseIf() else try self.parseBlock()).toOptional()
    else
        .none;

    const start = self.extraStart();
    try self.extraNode(cond);
    try self.extraOpt(capture);
    try self.extraNode(then_block);
    try self.extraOpt(else_node);
    return self.addNode(.{
        .tag = .if_expr,
        .main_token = if_token,
        .data = .{ .extra = start },
    });
}

fn parseReturn(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_return));

    const return_token = self.nextToken();
    const operand: Node.OptionalIndex = if (starts_expr.contains(self.current()))
        (try self.parseExpr()).toOptional()
    else
        .none;
    return self.addNode(.{
        .tag = .return_expr,
        .main_token = return_token,
        .data = .{ .opt_node = operand },
    });
}

fn parseLoopExit(self: *Parse) Allocator.Error!Node.Index {
    assert(self.at(.kw_break) or self.at(.kw_continue));

    const tag: Node.Tag = if (self.at(.kw_break)) .break_expr else .continue_expr;
    const keyword = self.nextToken();
    return self.addNode(.{ .tag = tag, .main_token = keyword, .data = .{ .none = {} } });
}

/// `|v|`, naming an optional payload or a caught error.
fn parseCapture(self: *Parse) Allocator.Error!Node.OptionalIndex {
    assert(self.token_index.int() <= self.eof_index.int());
    if (self.eatToken(.pipe) == null) return .none;
    assert(self.tags[self.token_index.before(1).int()] == .pipe);
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_token, Token.Tag.ident.symbol(), null);
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
    return self.addNode(.{
        .tag = .while_stmt,
        .main_token = while_token,
        .data = .{ .extra = start },
    });
}

fn parseVarDecl(self: *Parse) Allocator.Error!Node.Index {
    const keyword = self.nextToken();
    // a report can reach `errors_max` and jump the cursor to end of file
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

    return self.addNode(.{
        .tag = .var_decl,
        .main_token = keyword,
        .data = .{ .opt_node_and_node = .{ type_expr, init_expr } },
    });
}

fn parseExprStatement(self: *Parse) Allocator.Error!Node.Index {
    const from = self.token_index;

    const lhs = try self.parseExpr();
    assert(lhs.int() < self.nodes.len);
    if (self.at(.eq) == false) {
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
    return self.addPair(.assign, eq, lhs, rhs);
}

// expressions

fn parseExpr(self: *Parse) Allocator.Error!Node.Index {
    return self.parseExprPrec(1);
}

fn parseExprPrec(self: *Parse, min_prec: u8) Allocator.Error!Node.Index {
    assert(min_prec > 0);
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;

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
    assert(lhs.int() < self.nodes.len);
    assert(self.tags[catch_token.int()] == .kw_catch);
    const capture = try self.parseCapture();
    const rhs = if (self.at(.l_brace)) try self.parseBlock() else try self.parseExprPrec(min_prec);

    const start = self.extraStart();
    try self.extraNode(lhs);
    try self.extraOpt(capture);
    try self.extraNode(rhs);
    return self.addNode(.{
        .tag = .catch_expr,
        .main_token = catch_token,
        .data = .{ .extra = start },
    });
}

fn parsePrefixExpr(self: *Parse) Allocator.Error!Node.Index {
    // these build their own node rather than wrapping an operand
    const node_tag: Node.Tag = switch (self.current()) {
        .kw_if => return self.parseIf(),
        .kw_return => return self.parseReturn(),
        .kw_break, .kw_continue => return self.parseLoopExit(),
        .kw_try => .try_expr,
        .minus, .bang, .ampersand => .unary,
        else => return self.parseSuffixExpr(),
    };
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;

    const op_token = self.nextToken();
    const operand = try self.parsePrefixExpr();
    return self.addNode(.{ .tag = node_tag, .main_token = op_token, .data = .{ .node = operand } });
}

fn parseSuffixExpr(self: *Parse) Allocator.Error!Node.Index {
    var node = try self.parsePrimaryExpr();
    assert(node.int() < self.nodes.len);
    // each suffix wraps the one before, so a chain is still tree depth
    var suffixes: u32 = 0;

    while (true) {
        if (suffixes >= depth_max) return self.tooDeep();
        suffixes += 1;
        switch (self.current()) {
            .l_paren => node = try self.parseCall(node),
            .l_bracket => node = try self.parseInstance(node),
            .dot => node = try self.parseFieldAccess(node) orelse return self.hole(),
            else => return node,
        }
    }
}

fn parseCall(self: *Parse, callee: Node.Index) Allocator.Error!Node.Index {
    assert(self.at(.l_paren));
    assert(callee.int() < self.nodes.len);
    const lparen = self.nextToken();
    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);

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
    return self.addNode(.{
        .tag = .call,
        .main_token = lparen,
        .data = .{ .extra = start },
    });
}

/// `Box[i64]` in a type and `create[Node]` in a call are one node.
fn parseInstance(self: *Parse, base: Node.Index) Allocator.Error!Node.Index {
    assert(self.at(.l_bracket));
    assert(base.int() < self.nodes.len);
    const lbracket = self.nextToken();
    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);

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
    return self.addNode(.{
        .tag = .instance,
        .main_token = lbracket,
        .data = .{ .extra = start },
    });
}

fn parsePrimaryExpr(self: *Parse) Allocator.Error!Node.Index {
    switch (self.current()) {
        .ident => return self.addLeaf(.ident),
        .number => return self.addLeaf(.number_literal),
        .kw_true, .kw_false => return self.addLeaf(.bool_literal),
        .kw_null => return self.addLeaf(.null_literal),
        .dot => return self.parseStructLiteral(),
        // parentheses group, and the tree already holds the grouping
        .l_paren => {
            const lparen = self.nextToken();
            const inner = try self.parseExpr();
            try self.expectClosing(.r_paren, lparen);
            return inner;
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
            try self.errExpected(.expected_expression, "an expression", null);
            return self.hole();
        },
    }
}

fn parseStructLiteral(self: *Parse) Allocator.Error!Node.Index {
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
    defer self.scratch.shrinkRetainingCapacity(top);

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
    return self.addNode(.{
        .tag = .struct_literal,
        .main_token = dot,
        .data = .{ .extra = start },
    });
}

fn parseFieldInit(self: *Parse) Allocator.Error!Node.Index {
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
    if (self.depth >= depth_max) return self.tooDeep();
    self.depth += 1;
    defer self.depth -= 1;

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
    if (self.at(.ident) == false) {
        try self.errExpected(.expected_type, "a type", null);
        return self.hole();
    }
    const path = try self.parsePath();
    return if (self.at(.l_bracket)) self.parseInstance(path) else path;
}
