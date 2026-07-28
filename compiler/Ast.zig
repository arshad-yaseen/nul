//! The syntax tree. `Parse` writes the packed form, `viewOf` reads it back.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @import("Token.zig");
const Tokenizer = @import("Tokenizer.zig");
const Parse = @import("Parse.zig");

const Ast = @This();

/// Borrowed, so the caller's `Source` must outlive the tree.
source: [:0]const u8,
tokens: Tokenizer.TokenList.Slice,
nodes: NodeList.Slice,
/// Variable-length children, in source order.
extra: []u32,
errors: []const Error,

pub const NodeList = std.MultiArrayList(Node);
pub const TokenIndex = u32;
pub const ExtraIndex = enum(u32) { _ };

pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!Ast {
    return Parse.run(gpa, source);
}

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra);
    gpa.free(tree.errors);
    tree.* = undefined;
}

// Storage

pub const Node = struct {
    tag: Tag,
    /// An operator, a keyword, or a call's `(`. Every other position derives from it.
    main_token: TokenIndex,
    data: Data,

    /// Index into `nodes`. Node 0 is always the root.
    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            const r: OptionalIndex = @enumFromInt(@intFromEnum(i));
            assert(r != .none);
            return r;
        }
    };

    /// `?Index` would be 8 bytes and blow the payload budget. One stolen `u32` value
    /// keeps it at 4 and still forces an `unwrap()`.
    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }
    };

    /// A contiguous run of children in `extra`.
    pub const ExtraRange = struct { start: ExtraIndex, end: ExtraIndex };

    pub const Tag = enum(u8) {
        root,
        use_decl,
        fn_decl,
        param,
        block,
        /// Both `let` and `var`, where `main_token` is the keyword.
        var_decl,
        return_stmt,
        /// `extra_range` is the condition, the then block, and the else node when there
        /// is one, itself a block or another `if_stmt`.
        if_stmt,
        /// `for { }` and `for cond { }`.
        for_stmt,
        break_stmt,
        continue_stmt,
        assign,
        call,
        field_access,
        grouped,
        /// A struct type, whose `extra_range` holds the fields.
        struct_type,
        /// One named field inside a struct, where `main_token` is the name.
        field,
        /// A pointer type, where `main_token` is `*` and `node` is the pointee.
        pointer_type,

        /// `main_token` is the operator.
        binary,
        unary,

        ident,
        number_literal,
        str_literal,
        /// `main_token` is `true` or `false`.
        bool_literal,

        err,
    };

    /// Eight bytes reinterpreted by `tag`. Only `viewOf` reads it.
    pub const Data = union {
        none: void,
        node: Index,
        opt_node: OptionalIndex,
        node_and_node: struct { Index, Index },
        opt_node_and_node: struct { OptionalIndex, Index },
        extra_range: ExtraRange,
    };
};

comptime {
    assert(@sizeOf(Node.Tag) == 1);
    // Eight bytes of indexes, never pointers, so a payload means the same thing
    // wherever the tree is.
    if (!std.debug.runtime_safety) assert(@sizeOf(Node.Data) == 8);
}

// The view

pub const BinaryOp = enum(u4) {
    add,
    sub,
    mul,
    div,
    mod,
    equal,
    not_equal,
    less_than,
    less_or_equal,
    greater_than,
    greater_or_equal,
    bool_and,
    bool_or,
};

pub const UnaryOp = enum { negate, bool_not };

pub const Assoc = enum(u1) { left, none };

/// `prec` 0 means the token is not an infix operator.
pub const OperInfo = packed struct(u16) {
    prec: u5 = 0,
    assoc: Assoc = .left,
    op: BinaryOp = .add,
    _pad: u6 = 0,
};

/// The one place a token maps to the operator it means. `Parse` reads `prec` and
/// `assoc`; `viewOf` reads `op` back off the token.
pub const oper_table: [Token.tag_count]OperInfo = blk: {
    var t: [Token.tag_count]OperInfo = @splat(.{});
    for (.{
        .{ Token.Tag.kw_or, 1, Assoc.left, BinaryOp.bool_or },
        .{ Token.Tag.kw_and, 2, Assoc.left, BinaryOp.bool_and },
        .{ Token.Tag.eq_eq, 3, Assoc.none, BinaryOp.equal },
        .{ Token.Tag.bang_eq, 3, Assoc.none, BinaryOp.not_equal },
        .{ Token.Tag.lt, 3, Assoc.none, BinaryOp.less_than },
        .{ Token.Tag.lt_eq, 3, Assoc.none, BinaryOp.less_or_equal },
        .{ Token.Tag.gt, 3, Assoc.none, BinaryOp.greater_than },
        .{ Token.Tag.gt_eq, 3, Assoc.none, BinaryOp.greater_or_equal },
        .{ Token.Tag.plus, 4, Assoc.left, BinaryOp.add },
        .{ Token.Tag.minus, 4, Assoc.left, BinaryOp.sub },
        .{ Token.Tag.star, 5, Assoc.left, BinaryOp.mul },
        .{ Token.Tag.slash, 5, Assoc.left, BinaryOp.div },
        .{ Token.Tag.percent, 5, Assoc.left, BinaryOp.mod },
    }) |e| t[@intFromEnum(e[0])] = .{ .prec = e[1], .assoc = e[2], .op = e[3] };
    break :blk t;
};

pub const View = union(enum) {
    root: []const Node.Index,
    block: []const Node.Index,
    struct_type: []const Node.Index,
    use_decl: Node.Index,
    grouped: Node.Index,
    pointer_type: Pointer,
    return_stmt: Node.OptionalIndex,
    break_stmt: TokenIndex,
    continue_stmt: TokenIndex,

    fn_decl: FnDecl,
    var_decl: VarDecl,
    if_stmt: If,
    for_stmt: For,
    call: Call,
    binary: Binary,
    unary: Unary,
    param: TypedName,
    field: TypedName,
    field_access: FieldAccess,
    assign: Assign,

    ident: TokenIndex,
    number_literal: TokenIndex,
    str_literal: TokenIndex,
    bool_literal: struct { value: bool, token: TokenIndex },

    err,

    pub const FnDecl = struct {
        name_token: TokenIndex,
        is_pub: bool,
        params: []const Node.Index,
        return_type: Node.OptionalIndex,
        body: Node.Index,
    };
    pub const VarDecl = struct {
        name_token: TokenIndex,
        is_mutable: bool,
        is_pub: bool,
        type_expr: Node.OptionalIndex,
        init_expr: Node.Index,
    };
    /// Mutability is a token, never a stored bit.
    pub const Pointer = struct { is_mutable: bool, child: Node.Index };
    /// `else_node` is a block, or an `if_stmt` when the source chained `else if`.
    pub const If = struct { cond: Node.Index, then_block: Node.Index, else_node: Node.OptionalIndex };
    /// No condition is `for { }`, which only a `break` or `return` leaves.
    pub const For = struct { cond: Node.OptionalIndex, body: Node.Index };
    pub const TypedName = struct { name_token: TokenIndex, type_expr: Node.Index };
    pub const Call = struct { callee: Node.Index, args: []const Node.Index };
    pub const FieldAccess = struct { lhs: Node.Index, name_token: TokenIndex };
    pub const Assign = struct { lhs: Node.Index, rhs: Node.Index };
    pub const Binary = struct { op: BinaryOp, op_token: TokenIndex, lhs: Node.Index, rhs: Node.Index };
    pub const Unary = struct { op: UnaryOp, op_token: TokenIndex, operand: Node.Index };
};

pub fn viewOf(tree: Ast, n: Node.Index) View {
    const main = tree.nodeMainToken(n);
    const data = tree.nodes.items(.data)[@intFromEnum(n)];
    return switch (tree.nodeTag(n)) {
        .root => .{ .root = tree.nodesIn(data.extra_range) },
        .block => .{ .block = tree.nodesIn(data.extra_range) },
        .struct_type => .{ .struct_type = tree.nodesIn(data.extra_range) },
        .use_decl => .{ .use_decl = data.node },
        .grouped => .{ .grouped = data.node },
        .pointer_type => .{ .pointer_type = .{
            .is_mutable = tree.tokenTag(main + 1) == .kw_var,
            .child = data.node,
        } },
        .return_stmt => .{ .return_stmt = data.opt_node },
        .break_stmt => .{ .break_stmt = main },
        .continue_stmt => .{ .continue_stmt = main },
        .err => .err,

        // `if cond { } else ...`. `extra` is the condition, then block, and else.
        .if_stmt => blk: {
            const s = @intFromEnum(data.extra_range.start);
            const e = @intFromEnum(data.extra_range.end);
            assert(e - s >= 2); // the parser always appends the condition and then block
            break :blk .{ .if_stmt = .{
                .cond = @enumFromInt(tree.extra[s]),
                .then_block = @enumFromInt(tree.extra[s + 1]),
                .else_node = if (e - s > 2) @enumFromInt(tree.extra[s + 2]) else .none,
            } };
        },
        .for_stmt => .{ .for_stmt = .{
            .cond = data.opt_node_and_node[0],
            .body = data.opt_node_and_node[1],
        } },

        .param => .{ .param = .{ .name_token = main, .type_expr = data.node } },
        .field => .{ .field = .{ .name_token = main, .type_expr = data.node } },
        .field_access => .{ .field_access = .{ .lhs = data.node, .name_token = main + 1 } },
        .assign => .{ .assign = .{
            .lhs = data.node_and_node[0],
            .rhs = data.node_and_node[1],
        } },

        // `fn name(params) Ret { body }`. `extra` is params, return type, body.
        .fn_decl => blk: {
            const s = @intFromEnum(data.extra_range.start);
            const e = @intFromEnum(data.extra_range.end);
            assert(e - s >= 2); // the parser always appends the return type and body
            break :blk .{ .fn_decl = .{
                .name_token = main + 1,
                .is_pub = main > 0 and tree.tokenTag(main - 1) == .kw_pub,
                .params = @ptrCast(tree.extra[s .. e - 2]),
                .return_type = @enumFromInt(tree.extra[e - 2]),
                .body = @enumFromInt(tree.extra[e - 1]),
            } };
        },
        // `callee(args)`. `extra` is the callee, then the arguments.
        .call => blk: {
            const s = @intFromEnum(data.extra_range.start);
            const e = @intFromEnum(data.extra_range.end);
            assert(e > s); // the parser always appends the callee
            break :blk .{ .call = .{
                .callee = @enumFromInt(tree.extra[s]),
                .args = @ptrCast(tree.extra[s + 1 .. e]),
            } };
        },

        .var_decl => .{ .var_decl = .{
            .name_token = main + 1,
            .is_mutable = tree.tokenTag(main) == .kw_var,
            .is_pub = main > 0 and tree.tokenTag(main - 1) == .kw_pub,
            .type_expr = data.opt_node_and_node[0],
            .init_expr = data.opt_node_and_node[1],
        } },

        .binary => blk: {
            const info = oper_table[@intFromEnum(tree.tokenTag(main))];
            assert(info.prec != 0); // a binary node's main_token is an infix operator
            break :blk .{ .binary = .{
                .op = info.op,
                .op_token = main,
                .lhs = data.node_and_node[0],
                .rhs = data.node_and_node[1],
            } };
        },
        .unary => .{ .unary = .{
            .op = switch (tree.tokenTag(main)) {
                .minus => .negate,
                .bang => .bool_not,
                else => unreachable,
            },
            .op_token = main,
            .operand = data.node,
        } },

        .ident => .{ .ident = main },
        .number_literal => .{ .number_literal = main },
        .str_literal => .{ .str_literal = main },
        .bool_literal => .{ .bool_literal = .{
            .value = tree.tokenTag(main) == .kw_true,
            .token = main,
        } },
    };
}

fn nodesIn(tree: Ast, range: Node.ExtraRange) []const Node.Index {
    return @ptrCast(tree.extra[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

// Access

pub fn nodeTag(tree: Ast, n: Node.Index) Node.Tag {
    return tree.nodes.items(.tag)[@intFromEnum(n)];
}

pub fn firstToken(tree: Ast, node: Node.Index) TokenIndex {
    return switch (tree.viewOf(node)) {
        .ident, .number_literal, .str_literal => |token| token,
        .bool_literal => |it| it.token,
        .param, .field => |it| it.name_token,
        .binary => |it| tree.firstToken(it.lhs),
        .field_access => |it| tree.firstToken(it.lhs),
        .assign => |it| tree.firstToken(it.lhs),
        .call => |it| tree.firstToken(it.callee),
        else => tree.nodeMainToken(node),
    };
}

/// The last token of a node's span, so a label can underline all of it.
pub fn lastToken(tree: Ast, node: Node.Index) TokenIndex {
    return switch (tree.viewOf(node)) {
        .ident, .number_literal, .str_literal => |token| token,
        .bool_literal => |it| it.token,
        .field_access => |it| it.name_token,
        .binary => |it| tree.lastToken(it.rhs),
        .assign => |it| tree.lastToken(it.rhs),
        .unary => |it| tree.lastToken(it.operand),
        .grouped => |inner| tree.lastToken(inner) + 1,
        .pointer_type => |it| tree.lastToken(it.child),
        .param, .field => |it| tree.lastToken(it.type_expr),
        .var_decl => |it| tree.lastToken(it.init_expr),
        .return_stmt => |it| if (it.unwrap()) |e| tree.lastToken(e) else tree.nodeMainToken(node),
        .if_stmt => |it| tree.lastToken(it.else_node.unwrap() orelse it.then_block),
        .for_stmt => |it| tree.lastToken(it.body),
        .break_stmt, .continue_stmt => |token| token,
        // The closing token is not stored, and always follows what it closes.
        .call => |it| 1 + if (it.args.len > 0)
            tree.lastToken(it.args[it.args.len - 1])
        else
            tree.nodeMainToken(node),
        // A statement's newline puts a semicolon between it and the brace.
        .block, .struct_type, .root => |stmts| if (stmts.len > 0)
            tree.pastSemis(tree.lastToken(stmts[stmts.len - 1]))
        else
            tree.nodeMainToken(node) + 1,
        .use_decl => |child| tree.lastToken(child),
        .fn_decl => |it| tree.lastToken(it.body),
        .err => tree.nodeMainToken(node),
    };
}

pub fn nodeMainToken(tree: Ast, n: Node.Index) TokenIndex {
    return tree.nodes.items(.main_token)[@intFromEnum(n)];
}

fn pastSemis(tree: Ast, token: TokenIndex) TokenIndex {
    var at = token + 1;
    while (tree.tokenTag(at) == .semi) at += 1;
    return at;
}

pub fn tokenTag(tree: Ast, i: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[i];
}

pub fn tokenStart(tree: Ast, i: TokenIndex) u32 {
    return tree.tokens.items(.start)[i];
}

pub fn tokenSlice(tree: Ast, i: TokenIndex) []const u8 {
    const tag = tree.tokenTag(i);
    const start = tree.tokenStart(i);
    return tree.source[start..Tokenizer.tokenEnd(tree.source, tag, start)];
}

// Errors

pub const Error = struct {
    tag: Tag,
    token: TokenIndex,
    expected: ?Token.Tag = null,

    /// Explicit and permanent, like `Diagnostic.Tag`'s. Parse errors own E01xx.
    pub const Tag = enum(u16) {
        expected_token = 101,
        expected_expr = 102,
        expected_statement = 103,
        expected_top_level_decl = 104,
        expected_param = 105,
        expected_field = 106,
        chained_comparison = 107,
        invalid_assign_target = 108,
        nesting_too_deep = 109,
        invalid_bytes = 110,
        stray_else = 111,
    };

    pub fn render(err: Error, tree: Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const found = tree.tokenTag(err.token).symbol();
        switch (err.tag) {
            .expected_token => try w.print("expected '{s}', found {s}", .{
                err.expected.?.lexeme() orelse err.expected.?.symbol(),
                found,
            }),
            .expected_expr => try w.print("expected an expression, found {s}", .{found}),
            .expected_statement => try w.print("expected a statement, found {s}", .{found}),
            .expected_top_level_decl => try w.print("expected a declaration, found {s}", .{found}),
            .expected_param => try w.print("expected a parameter, found {s}", .{found}),
            .expected_field => try w.print("expected a field, found {s}", .{found}),
            .chained_comparison => try w.writeAll("comparison operators cannot be chained"),
            .invalid_assign_target => try w.writeAll("cannot assign to this expression"),
            .nesting_too_deep => try w.writeAll("expression nests too deeply"),
            .invalid_bytes => try w.writeAll("invalid bytes"),
            .stray_else => try w.writeAll(
                "'else' has no 'if' here. It has to sit on the same line as the '}' that closes one",
            ),
        }
    }
};
