//! Recursive descent over the token stream.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Token = @import("Token.zig");
const Tokenizer = @import("Tokenizer.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const Parse = @This();

/// Recursive descent lets adversarial input exhaust the stack. A limit with a real
/// diagnostic beats a crash.
const max_depth = 256;
/// Past this many errors the file is generated, not edited. Stop recording.
const max_errors = 128;

gpa: Allocator,
source: [:0]const u8,
tokens: Tokenizer.TokenList.Slice,
tok_i: TokenIndex,
nodes: Ast.NodeList,
extra: std.ArrayList(u32),
scratch: std.ArrayList(Node.Index),
errors: std.ArrayList(Ast.Error),
depth: u32,

fn estimatedNodeCount(n: usize) usize {
    return n * 3 / 4 + 8;
}

pub fn run(gpa: Allocator, source: [:0]const u8) Allocator.Error!Ast {
    var tokens: Tokenizer.TokenList = .empty;
    errdefer tokens.deinit(gpa);
    try Tokenizer.tokenizeAll(gpa, source, &tokens);

    var p: Parse = .{
        .gpa = gpa,
        .source = source,
        .tokens = tokens.slice(),
        .tok_i = 0,
        .nodes = .empty,
        .extra = .empty,
        .scratch = .empty,
        .errors = .empty,
        .depth = 0,
    };
    defer p.scratch.deinit(gpa);
    errdefer {
        p.nodes.deinit(gpa);
        p.extra.deinit(gpa);
        p.errors.deinit(gpa);
    }

    try p.nodes.ensureTotalCapacity(gpa, estimatedNodeCount(tokens.len));
    try p.parseRoot();

    return .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = p.nodes.toOwnedSlice(),
        .extra = try p.extra.toOwnedSlice(gpa),
        .errors = try p.errors.toOwnedSlice(gpa),
    };
}

// Cursor

inline fn tag(p: *const Parse) Token.Tag {
    return p.tokens.items(.tag)[p.tok_i];
}

inline fn at(p: *const Parse, t: Token.Tag) bool {
    return p.tag() == t;
}

inline fn eof(p: *const Parse) bool {
    return p.tag() == .eof;
}

fn nextToken(p: *Parse) TokenIndex {
    const i = p.tok_i;
    p.tok_i += 1;
    return i;
}

fn eatToken(p: *Parse, t: Token.Tag) ?TokenIndex {
    return if (p.at(t)) p.nextToken() else null;
}

fn expectToken(p: *Parse, t: Token.Tag) Allocator.Error!void {
    if (p.eatToken(t) == null) {
        try p.addError(.{ .tag = .expected_token, .token = p.tok_i, .expected = t });
    }
}

fn expectSemi(p: *Parse) Allocator.Error!void {
    switch (p.tag()) {
        .semi => p.tok_i += 1,
        .r_brace, .eof => {},
        else => try p.addError(.{ .tag = .expected_token, .token = p.tok_i, .expected = .semi }),
    }
}

/// The single reason no input can hang the parser.
fn ensureProgress(p: *Parse, before: TokenIndex) void {
    if (p.tok_i == before and !p.eof()) p.tok_i += 1;
}

// Building

fn addNode(p: *Parse, node: Node) Allocator.Error!Node.Index {
    const i: Node.Index = @enumFromInt(p.nodes.len);
    try p.nodes.append(p.gpa, node);
    return i;
}

fn addLeaf(p: *Parse, node_tag: Node.Tag) Allocator.Error!Node.Index {
    return p.addNode(.{ .tag = node_tag, .main_token = p.nextToken(), .data = .{ .none = {} } });
}

fn storeChildren(p: *Parse, list: []const Node.Index) Allocator.Error!Node.ExtraRange {
    try p.extra.appendSlice(p.gpa, @ptrCast(list));
    return .{
        .start = @enumFromInt(p.extra.items.len - list.len),
        .end = @enumFromInt(p.extra.items.len),
    };
}

fn addError(p: *Parse, err: Ast.Error) Allocator.Error!void {
    @branchHint(.cold);
    if (p.errors.items.len >= max_errors) return;
    try p.errors.append(p.gpa, err);
}

fn errNodeReporting(p: *Parse, err: Ast.Error) Allocator.Error!Node.Index {
    @branchHint(.cold);
    try p.addError(err);
    return p.addNode(.{ .tag = .err, .main_token = err.token, .data = .{ .none = {} } });
}

fn errNode(p: *Parse, err_tag: Ast.Error.Tag) Allocator.Error!Node.Index {
    return p.errNodeReporting(.{ .tag = err_tag, .token = p.tok_i });
}

fn errNodeAdvance(p: *Parse, err_tag: Ast.Error.Tag) Allocator.Error!Node.Index {
    const n = try p.errNode(err_tag);
    if (!p.eof()) p.tok_i += 1;
    return n;
}

fn errNodeExpecting(p: *Parse, expected: Token.Tag) Allocator.Error!Node.Index {
    return p.errNodeReporting(.{
        .tag = .expected_token,
        .token = p.tok_i,
        .expected = expected,
    });
}

const TokenSet = std.EnumSet(Token.Tag);

const starts_expr = TokenSet.initMany(&.{
    .ident,   .number, .str,  .kw_true, .kw_false,
    .l_paren, .minus,  .bang, .star,    .kw_struct,
});

const starts_stmt = starts_expr.unionWith(TokenSet.initMany(&.{ .kw_let, .kw_var, .kw_return }));

/// Tokens that can only start a top-level declaration.
const starts_decl = TokenSet.initMany(&.{ .kw_use, .kw_fn, .kw_pub });

const recover_in_block = starts_decl.unionWith(TokenSet.initMany(&.{.r_brace}));
const recover_in_params = starts_decl.unionWith(TokenSet.initMany(&.{ .r_paren, .l_brace }));
const recover_in_args = starts_decl.unionWith(TokenSet.initMany(&.{ .r_paren, .r_brace, .semi }));

// Declarations

fn parseRoot(p: *Parse) Allocator.Error!void {
    try p.nodes.append(p.gpa, .{ .tag = .root, .main_token = 0, .data = .{ .none = {} } });

    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);

    while (!p.eof()) {
        const before = p.tok_i;
        switch (p.tag()) {
            // Stray terminators, and doc comments, not attached yet.
            .semi, .doc_comment => p.tok_i += 1,
            .kw_use => try p.scratch.append(p.gpa, try p.parseUseDecl()),
            .kw_fn => try p.scratch.append(p.gpa, try p.parseFnDecl()),
            .kw_pub => switch (p.tokens.items(.tag)[p.tok_i + 1]) {
                .kw_let, .kw_var => {
                    p.tok_i += 1;
                    try p.scratch.append(p.gpa, try p.parseVarDecl());
                },
                else => try p.scratch.append(p.gpa, try p.parseFnDecl()),
            },
            // Types are values, so a type declaration is an ordinary binding.
            .kw_let, .kw_var => try p.scratch.append(p.gpa, try p.parseVarDecl()),
            .invalid => try p.scratch.append(p.gpa, try p.errNodeAdvance(.invalid_bytes)),
            else => try p.scratch.append(p.gpa, try p.errNodeAdvance(.expected_top_level_decl)),
        }
        p.ensureProgress(before);
    }

    const span = try p.storeChildren(p.scratch.items[top..]);
    p.nodes.items(.data)[0] = .{ .extra_range = span };
}

fn parseUseDecl(p: *Parse) Allocator.Error!Node.Index {
    const use_token = p.nextToken();
    const path = try p.parseExpr();
    try p.expectSemi();
    return p.addNode(.{ .tag = .use_decl, .main_token = use_token, .data = .{ .node = path } });
}

fn parseFnDecl(p: *Parse) Allocator.Error!Node.Index {
    _ = p.eatToken(.kw_pub);
    const fn_token = p.eatToken(.kw_fn) orelse return p.errNodeAdvance(.expected_top_level_decl);
    try p.expectToken(.ident);

    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);

    try p.expectToken(.l_paren);
    while (!p.at(.r_paren) and !p.eof()) {
        const before = p.tok_i;
        if (p.at(.doc_comment)) {
            p.tok_i += 1;
            continue;
        }
        if (p.at(.ident)) {
            try p.scratch.append(p.gpa, try p.parseParam());
        } else if (recover_in_params.contains(p.tag())) {
            break;
        } else {
            try p.scratch.append(p.gpa, try p.errNodeAdvance(.expected_param));
        }
        p.ensureProgress(before);
        if (p.eatToken(.comma) == null) break;
    }
    try p.expectToken(.r_paren);

    // A return type only if something can start an expression.
    const return_type: Node.OptionalIndex = if (starts_expr.contains(p.tag()))
        (try p.parseExpr()).toOptional()
    else
        .none;
    const body = try p.parseBlock();

    // `extra` mirrors source order, params, then return type, then body.
    try p.scratch.append(p.gpa, @enumFromInt(@intFromEnum(return_type)));
    try p.scratch.append(p.gpa, body);

    return p.addNode(.{
        .tag = .fn_decl,
        .main_token = fn_token,
        .data = .{ .extra_range = try p.storeChildren(p.scratch.items[top..]) },
    });
}

/// A `struct` keyword and its braced list of named fields.
fn parseStructType(p: *Parse) Allocator.Error!Node.Index {
    const struct_token = p.nextToken();

    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);

    try p.expectToken(.l_brace);
    while (!p.at(.r_brace) and !p.eof()) {
        const before = p.tok_i;
        if (p.at(.semi) or p.at(.doc_comment)) {
            p.tok_i += 1;
        } else if (p.at(.ident)) {
            try p.scratch.append(p.gpa, try p.parseField());
        } else if (recover_in_block.contains(p.tag())) {
            break;
        } else {
            try p.scratch.append(p.gpa, try p.errNodeAdvance(.expected_field));
        }
        p.ensureProgress(before);
    }
    try p.expectToken(.r_brace);

    return p.addNode(.{
        .tag = .struct_type,
        .main_token = struct_token,
        .data = .{ .extra_range = try p.storeChildren(p.scratch.items[top..]) },
    });
}

fn parseField(p: *Parse) Allocator.Error!Node.Index {
    const name_token = p.nextToken();
    try p.expectToken(.colon);
    const type_expr = try p.parseExpr();
    try p.expectSemi();
    return p.addNode(.{ .tag = .field, .main_token = name_token, .data = .{ .node = type_expr } });
}

fn parseParam(p: *Parse) Allocator.Error!Node.Index {
    const name_token = p.nextToken();
    try p.expectToken(.colon);
    const type_expr = try p.parseExpr();
    return p.addNode(.{ .tag = .param, .main_token = name_token, .data = .{ .node = type_expr } });
}

// Statements

fn parseBlock(p: *Parse) Allocator.Error!Node.Index {
    if (!p.at(.l_brace)) return p.errNodeExpecting(.l_brace);
    if (p.depth >= max_depth) return p.errNode(.nesting_too_deep);
    p.depth += 1;
    defer p.depth -= 1;

    const lbrace = p.nextToken();
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);

    while (!p.at(.r_brace) and !p.eof()) {
        const before = p.tok_i;
        if (p.at(.semi) or p.at(.doc_comment)) {
            p.tok_i += 1;
        } else if (starts_stmt.contains(p.tag())) {
            try p.scratch.append(p.gpa, try p.parseStatement());
        } else if (recover_in_block.contains(p.tag())) {
            break;
        } else {
            try p.scratch.append(p.gpa, try p.errNodeAdvance(.expected_statement));
        }
        p.ensureProgress(before);
    }
    try p.expectToken(.r_brace);

    const span = try p.storeChildren(p.scratch.items[top..]);
    return p.addNode(.{ .tag = .block, .main_token = lbrace, .data = .{ .extra_range = span } });
}

fn parseStatement(p: *Parse) Allocator.Error!Node.Index {
    switch (p.tag()) {
        .kw_let, .kw_var => return p.parseVarDecl(),
        .kw_return => {
            const return_token = p.nextToken();
            const operand: Node.OptionalIndex = if (starts_expr.contains(p.tag()))
                (try p.parseExpr()).toOptional()
            else
                .none;
            try p.expectSemi();
            return p.addNode(.{
                .tag = .return_stmt,
                .main_token = return_token,
                .data = .{ .opt_node = operand },
            });
        },
        else => return p.parseExprStatement(),
    }
}

fn parseVarDecl(p: *Parse) Allocator.Error!Node.Index {
    const kw = p.nextToken();
    try p.expectToken(.ident);

    const type_expr: Node.OptionalIndex = if (p.eatToken(.colon) != null)
        (try p.parseExpr()).toOptional()
    else
        .none;

    try p.expectToken(.eq);
    const init_expr = try p.parseExpr();
    try p.expectSemi();

    return p.addNode(.{
        .tag = .var_decl,
        .main_token = kw,
        .data = .{ .opt_node_and_node = .{ type_expr, init_expr } },
    });
}

fn parseExprStatement(p: *Parse) Allocator.Error!Node.Index {
    const lhs = try p.parseExpr();

    if (p.eatToken(.eq)) |eq_token| {
        // `1 = x` is a parse error, not a semantic one, so it stays out of Sema.
        switch (p.nodes.items(.tag)[@intFromEnum(lhs)]) {
            .ident, .field_access, .err => {},
            else => try p.addError(.{
                .tag = .invalid_assign_target,
                .token = p.nodes.items(.main_token)[@intFromEnum(lhs)],
            }),
        }
        const rhs = try p.parseExpr();
        try p.expectSemi();
        return p.addNode(.{
            .tag = .assign,
            .main_token = eq_token,
            .data = .{ .node_and_node = .{ lhs, rhs } },
        });
    }

    try p.expectSemi();
    return lhs;
}

// Expressions

fn parseExpr(p: *Parse) Allocator.Error!Node.Index {
    return p.parseExprPrec(1);
}

fn parseExprPrec(p: *Parse, min_prec: u5) Allocator.Error!Node.Index {
    if (p.depth >= max_depth) return p.errNode(.nesting_too_deep);
    p.depth += 1;
    defer p.depth -= 1;

    var node = try p.parsePrefixExpr();
    var banned_prec: u5 = 0;

    while (true) {
        const info = Ast.oper_table[@intFromEnum(p.tag())];
        if (info.prec < min_prec) break;
        if (info.prec == banned_prec) {
            try p.addError(.{ .tag = .chained_comparison, .token = p.tok_i });
        }

        const op_token = p.nextToken();
        const rhs = try p.parseExprPrec(info.prec + 1);
        node = try p.addNode(.{
            .tag = .binary,
            .main_token = op_token,
            .data = .{ .node_and_node = .{ node, rhs } },
        });

        if (info.assoc == .none) banned_prec = info.prec;
    }
    return node;
}

fn parsePrefixExpr(p: *Parse) Allocator.Error!Node.Index {
    const node_tag: Node.Tag = switch (p.tag()) {
        .minus, .bang => .unary,
        .star => .pointer_type,
        else => return p.parseSuffixExpr(),
    };
    if (p.depth >= max_depth) return p.errNode(.nesting_too_deep);
    p.depth += 1;
    defer p.depth -= 1;

    const op_token = p.nextToken();

    // `Ast.viewOf` reads mutability off the token after `*`, so nothing is stored.
    if (node_tag == .pointer_type) _ = p.eatToken(.kw_var);

    return p.addNode(.{
        .tag = node_tag,
        .main_token = op_token,
        .data = .{ .node = try p.parsePrefixExpr() },
    });
}

fn parseSuffixExpr(p: *Parse) Allocator.Error!Node.Index {
    var node = try p.parsePrimaryExpr();
    while (true) switch (p.tag()) {
        .l_paren => node = try p.parseCall(node),
        .dot => {
            const dot_token = p.nextToken();
            if (p.eatToken(.ident) == null) return p.errNodeExpecting(.ident);
            node = try p.addNode(.{
                .tag = .field_access,
                .main_token = dot_token,
                .data = .{ .node = node },
            });
        },
        else => return node,
    };
}

fn parseCall(p: *Parse, callee: Node.Index) Allocator.Error!Node.Index {
    const lparen = p.nextToken();
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);

    // `extra` mirrors source order, the callee, then the arguments.
    try p.scratch.append(p.gpa, callee);

    while (!p.at(.r_paren) and !p.eof()) {
        const before = p.tok_i;
        if (starts_expr.contains(p.tag())) {
            try p.scratch.append(p.gpa, try p.parseExpr());
        } else if (recover_in_args.contains(p.tag())) {
            break;
        } else {
            try p.scratch.append(p.gpa, try p.errNodeAdvance(.expected_expr));
        }
        p.ensureProgress(before);
        if (p.eatToken(.comma) == null) break;
    }
    try p.expectToken(.r_paren);

    return p.addNode(.{
        .tag = .call,
        .main_token = lparen,
        .data = .{ .extra_range = try p.storeChildren(p.scratch.items[top..]) },
    });
}

fn parsePrimaryExpr(p: *Parse) Allocator.Error!Node.Index {
    switch (p.tag()) {
        .ident => return p.addLeaf(.ident),
        .number => return p.addLeaf(.number_literal),
        .str => return p.addLeaf(.str_literal),
        .kw_true, .kw_false => return p.addLeaf(.bool_literal),
        .kw_struct => return p.parseStructType(),
        .l_paren => {
            const lparen = p.nextToken();
            const inner = try p.parseExpr();
            try p.expectToken(.r_paren);
            return p.addNode(.{ .tag = .grouped, .main_token = lparen, .data = .{ .node = inner } });
        },
        else => return p.errNode(.expected_expr),
    }
}
