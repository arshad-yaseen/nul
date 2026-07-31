//! The syntax tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Diagnostic = @import("Diagnostic.zig");
const Parse = @import("Parse.zig");
const Token = @import("Token.zig");
const Tokenizer = @import("Tokenizer.zig");

const AST = @This();

/// Borrowed, so the caller's `Source` must outlive the tree.
source: [:0]const u8,
/// In source order, ending in one `.eof`.
tokens: Tokenizer.TokenList.Slice,
/// Node 0 is the root.
nodes: NodeList.Slice,
/// Every variable-length payload, read back through `Fields`.
extra: []const u32,
/// Empty when the file parsed. Anything here stops the tree from being analyzed.
errors: []const Diagnostic,
/// Backs `errors` and every string in it, so freeing them is one call.
error_text: std.heap.ArenaAllocator.State,

pub const NodeList = std.MultiArrayList(Node);
/// Where a node's payload starts in `extra`.
pub const ExtraIndex = enum(u32) { _ };

pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!AST {
    const tree = try Parse.run(gpa, source);

    assert(tree.nodes.len > 0);
    assert(tree.nodeTag(.root) == .root);
    return tree;
}

pub fn deinit(tree: *AST, gpa: Allocator) void {
    assert(tree.nodes.len > 0);
    assert(tree.tokens.len > 0);

    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra);
    tree.error_text.promote(gpa).deinit();
    tree.* = undefined;
}

// storage

pub const Node = struct {
    tag: Tag,
    /// The keyword or operator the node is named by. Every other token position
    /// is derived from it or stored in `extra`.
    main_token: Token.Index,
    data: Data,

    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn int(index: Index) u32 {
            return @intFromEnum(index);
        }

        pub fn toOptional(i: Index) OptionalIndex {
            const optional: OptionalIndex = @enumFromInt(@intFromEnum(i));
            assert(optional != .none);
            return optional;
        }
    };

    /// `?Index` would be eight bytes and blow the payload budget. One stolen
    /// value keeps it at four and still forces an `unwrap()`.
    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(optional: OptionalIndex) ?Index {
            if (optional == .none) return null;
            assert(@intFromEnum(optional) != @intFromEnum(OptionalIndex.none));
            return @enumFromInt(@intFromEnum(optional));
        }
    };

    pub const Tag = enum(u8) {
        root,
        use_decl,
        struct_decl,
        type_decl,
        fn_decl,
        /// Both `let` and `var`, told apart by `main_token`.
        var_decl,
        /// One name in a `[T, U]` list. A constraint is reported, never stored.
        type_param,
        param,
        field,

        block,
        assign,
        defer_stmt,
        if_stmt,
        while_stmt,
        break_stmt,
        continue_stmt,
        return_stmt,
        /// The `v` of `|v|`, on an `if` or a `catch`.
        capture,

        ident,
        number_literal,
        bool_literal,
        null_literal,

        field_access,
        /// `Name[A, B]` in a type, `f[T]` in a call. One concept, one node.
        instance,
        call,
        /// `.{ ... }`, whose type comes from context.
        struct_literal,
        struct_field_init,
        /// `error.Name`, a member of the one universal error set.
        error_value,

        try_expr,
        orelse_expr,
        catch_expr,
        binary,
        unary,
        grouped,

        pointer_type,
        optional_type,
        /// `!T`, over the one universal error set, so it names nothing.
        error_union_type,

        /// A hole where parsing failed. It keeps the tree's shape, so a walk
        /// still reaches everything around it.
        err,
    };

    /// Eight bytes reinterpreted by `tag`. Only `viewOf` reads it.
    pub const Data = union {
        none: void,
        node: Index,
        opt_node: OptionalIndex,
        node_and_node: struct { Index, Index },
        opt_node_and_node: struct { OptionalIndex, Index },
        /// Where `Fields` starts reading.
        extra: ExtraIndex,
    };
};

comptime {
    // every tag has exactly one view, matched by name, so adding a tag without
    // teaching `viewOf` about it is a compile error rather than a wrong read
    const tags = @typeInfo(Node.Tag).@"enum".fields;
    const views = @typeInfo(View).@"union".fields;
    assert(tags.len == views.len);
    for (tags, views) |tag, view| assert(std.mem.eql(u8, tag.name, view.name));

    assert(@sizeOf(Node.Tag) == 1);
    assert(@sizeOf(Node.Index) == 4);
    assert(@sizeOf(ExtraIndex) == 4);
    // indexes, never pointers, so a payload means the same wherever the tree is
    // safe builds add a tag to the bare union
    if (std.debug.runtime_safety == false) assert(@sizeOf(Node.Data) == 8);
}

/// Reads a payload back in the order `Parse` wrote it. A list is a count
/// followed by that many indexes.
const Fields = struct {
    extra: []const u32,
    cursor: u32,

    fn node(payload: *Fields) Node.Index {
        assert(payload.cursor < payload.extra.len);
        defer payload.cursor += 1;
        return @enumFromInt(payload.extra[payload.cursor]);
    }

    fn optNode(payload: *Fields) Node.OptionalIndex {
        assert(payload.cursor < payload.extra.len);
        defer payload.cursor += 1;
        return @enumFromInt(payload.extra[payload.cursor]);
    }

    fn list(payload: *Fields) []const Node.Index {
        assert(payload.cursor < payload.extra.len);
        const length = payload.extra[payload.cursor];
        assert(payload.cursor + 1 + length <= payload.extra.len);

        defer payload.cursor += 1 + length;
        return @ptrCast(payload.extra[payload.cursor + 1 ..][0..length]);
    }
};

// the view

pub const BinaryOp = enum {
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

pub const UnaryOp = enum { negate, bool_not, address_of };

/// `none` bans chaining, so `a < b < c` is reported rather than nested.
pub const Assoc = enum { left, right, none };

pub const OperInfo = struct {
    /// Zero means the token is not an infix operator.
    prec: u8 = 0,
    assoc: Assoc = .left,
    /// Null for the tokens whose node is not `.binary`.
    op: ?BinaryOp = null,
};

/// The one place a token maps to the infix operator it means.
pub const oper_table: [Token.tag_count]OperInfo = blk: {
    var table: [Token.tag_count]OperInfo = @splat(.{});
    for (.{
        .{ Token.Tag.kw_or, 1, Assoc.left, BinaryOp.bool_or },
        .{ Token.Tag.kw_and, 2, Assoc.left, BinaryOp.bool_and },
        .{ Token.Tag.eq_eq, 3, Assoc.none, BinaryOp.equal },
        .{ Token.Tag.bang_eq, 3, Assoc.none, BinaryOp.not_equal },
        .{ Token.Tag.lt, 3, Assoc.none, BinaryOp.less_than },
        .{ Token.Tag.lt_eq, 3, Assoc.none, BinaryOp.less_or_equal },
        .{ Token.Tag.gt, 3, Assoc.none, BinaryOp.greater_than },
        .{ Token.Tag.gt_eq, 3, Assoc.none, BinaryOp.greater_or_equal },
        .{ Token.Tag.plus, 5, Assoc.left, BinaryOp.add },
        .{ Token.Tag.minus, 5, Assoc.left, BinaryOp.sub },
        .{ Token.Tag.star, 6, Assoc.left, BinaryOp.mul },
        .{ Token.Tag.slash, 6, Assoc.left, BinaryOp.div },
        .{ Token.Tag.percent, 6, Assoc.left, BinaryOp.mod },
    }) |entry| table[@intFromEnum(entry[0])] = .{
        .prec = entry[1],
        .assoc = entry[2],
        .op = entry[3],
    };
    // supplying a value binds looser than arithmetic and tighter than comparison,
    // and nests right, so `a orelse b orelse c` tries each in turn
    for (.{ Token.Tag.kw_orelse, Token.Tag.kw_catch }) |tag| {
        table[@intFromEnum(tag)] = .{ .prec = 4, .assoc = .right };
    }
    break :blk table;
};

/// The one place a token maps to the prefix operator it means.
pub const unary_table: [Token.tag_count]?UnaryOp = blk: {
    var table: [Token.tag_count]?UnaryOp = @splat(null);
    table[@intFromEnum(Token.Tag.minus)] = .negate;
    table[@intFromEnum(Token.Tag.bang)] = .bool_not;
    table[@intFromEnum(Token.Tag.ampersand)] = .address_of;
    break :blk table;
};

pub const View = union(enum) {
    root: []const Node.Index,
    use_decl: Use,
    struct_decl: StructDecl,
    type_decl: TypeDecl,
    fn_decl: FnDecl,
    var_decl: VarDecl,
    type_param: Token.Index,
    param: TypedName,
    field: TypedName,

    block: []const Node.Index,
    assign: Pair,
    defer_stmt: Node.Index,
    if_stmt: If,
    while_stmt: While,
    break_stmt: Token.Index,
    continue_stmt: Token.Index,
    return_stmt: Node.OptionalIndex,
    capture: Token.Index,

    ident: Token.Index,
    number_literal: Token.Index,
    bool_literal: Bool,
    null_literal: Token.Index,

    field_access: FieldAccess,
    instance: Instance,
    call: Call,
    struct_literal: []const Node.Index,
    struct_field_init: NamedValue,
    error_value: Token.Index,

    try_expr: Node.Index,
    orelse_expr: Pair,
    catch_expr: Catch,
    binary: Binary,
    unary: Unary,
    grouped: Node.Index,

    pointer_type: Pointer,
    optional_type: Node.Index,
    error_union_type: Node.Index,

    err,

    pub const Use = struct { is_pub: bool, path: Node.Index };
    pub const StructDecl = struct {
        name_token: Token.Index,
        is_pub: bool,
        type_params: []const Node.Index,
        members: []const Node.Index,
    };
    pub const TypeDecl = struct { name_token: Token.Index, is_pub: bool, aliased: Node.Index };
    pub const FnDecl = struct {
        name_token: Token.Index,
        is_pub: bool,
        type_params: []const Node.Index,
        params: []const Node.Index,
        /// `.none` is a function returning nothing.
        return_type: Node.OptionalIndex,
        /// A block, or the expression of an `= expr` body.
        body: Node.Index,
    };
    pub const VarDecl = struct {
        name_token: Token.Index,
        is_mutable: bool,
        is_pub: bool,
        /// `.none` when the initializer decides the type.
        type_expr: Node.OptionalIndex,
        init_expr: Node.Index,
    };
    pub const TypedName = struct { name_token: Token.Index, type_expr: Node.Index };
    pub const NamedValue = struct { name_token: Token.Index, value: Node.Index };
    pub const Pair = struct { lhs: Node.Index, rhs: Node.Index };
    /// `else_node` is a block, or another `if_stmt` for a chained `else if`.
    pub const If = struct {
        cond: Node.Index,
        capture: Node.OptionalIndex,
        then_block: Node.Index,
        else_node: Node.OptionalIndex,
    };
    /// No condition is `while { }`, which only a `break` or `return` leaves.
    /// `capture` names what the optional held, the same shape `if` uses.
    pub const While = struct {
        cond: Node.OptionalIndex,
        capture: Node.OptionalIndex,
        body: Node.Index,
    };
    pub const Instance = struct { base: Node.Index, args: []const Node.Index };
    pub const Call = struct { callee: Node.Index, args: []const Node.Index };
    /// `rhs` is a value, or the block of `a catch |err| { }`.
    pub const Catch = struct { lhs: Node.Index, capture: Node.OptionalIndex, rhs: Node.Index };
    pub const FieldAccess = struct { lhs: Node.Index, name_token: Token.Index };
    pub const Pointer = struct { is_mutable: bool, child: Node.Index };
    pub const Bool = struct { value: bool, token: Token.Index };
    pub const Binary = struct {
        op: BinaryOp,
        op_token: Token.Index,
        lhs: Node.Index,
        rhs: Node.Index,
    };
    pub const Unary = struct { op: UnaryOp, op_token: Token.Index, operand: Node.Index };
};

pub fn viewOf(tree: AST, node: Node.Index) View {
    assert(node.int() < tree.nodes.len);

    const main = tree.nodeMainToken(node);
    const data = tree.nodes.items(.data)[node.int()];
    const view = unpack(tree, tree.nodeTag(node), main, data);

    assert(std.mem.eql(u8, @tagName(view), @tagName(tree.nodeTag(node))));
    return view;
}

fn unpack(tree: AST, node_tag: Node.Tag, main: Token.Index, data: Node.Data) View {
    return switch (node_tag) {
        .root => .{ .root = tree.listAt(data.extra) },
        .use_decl => .{ .use_decl = .{ .is_pub = tree.isPub(main), .path = data.node } },
        .struct_decl => blk: {
            var payload = tree.fields(data.extra);
            break :blk .{ .struct_decl = .{
                .name_token = main.after(1),
                .is_pub = tree.isPub(main),
                .type_params = payload.list(),
                .members = payload.list(),
            } };
        },
        .type_decl => .{ .type_decl = .{
            .name_token = main.after(1),
            .is_pub = tree.isPub(main),
            .aliased = data.node,
        } },
        .fn_decl => blk: {
            var payload = tree.fields(data.extra);
            break :blk .{ .fn_decl = .{
                .name_token = main.after(1),
                .is_pub = tree.isPub(main),
                .type_params = payload.list(),
                .params = payload.list(),
                .return_type = payload.optNode(),
                .body = payload.node(),
            } };
        },
        .var_decl => .{ .var_decl = .{
            .name_token = main.after(1),
            .is_mutable = tree.tokenTag(main) == .kw_var,
            .is_pub = tree.isPub(main),
            .type_expr = data.opt_node_and_node[0],
            .init_expr = data.opt_node_and_node[1],
        } },
        .type_param => .{ .type_param = main },
        .param => .{ .param = .{ .name_token = main, .type_expr = data.node } },
        .field => .{ .field = .{ .name_token = main, .type_expr = data.node } },

        .block => .{ .block = tree.listAt(data.extra) },
        .assign => .{ .assign = .{
            .lhs = data.node_and_node[0],
            .rhs = data.node_and_node[1],
        } },
        .defer_stmt => .{ .defer_stmt = data.node },
        .if_stmt => blk: {
            var payload = tree.fields(data.extra);
            break :blk .{ .if_stmt = .{
                .cond = payload.node(),
                .capture = payload.optNode(),
                .then_block = payload.node(),
                .else_node = payload.optNode(),
            } };
        },
        .while_stmt => blk: {
            var payload = tree.fields(data.extra);
            break :blk .{ .while_stmt = .{
                .cond = payload.optNode(),
                .capture = payload.optNode(),
                .body = payload.node(),
            } };
        },
        .break_stmt => .{ .break_stmt = main },
        .continue_stmt => .{ .continue_stmt = main },
        .return_stmt => .{ .return_stmt = data.opt_node },
        .capture => .{ .capture = main },

        .ident => .{ .ident = main },
        .number_literal => .{ .number_literal = main },
        .bool_literal => .{ .bool_literal = .{
            .value = tree.tokenTag(main) == .kw_true,
            .token = main,
        } },
        .null_literal => .{ .null_literal = main },

        .field_access => .{ .field_access = .{ .lhs = data.node, .name_token = main.after(1) } },
        .instance => blk: {
            var payload = tree.fields(data.extra);
            break :blk .{ .instance = .{ .base = payload.node(), .args = payload.list() } };
        },
        .call => blk: {
            var payload = tree.fields(data.extra);
            break :blk .{ .call = .{ .callee = payload.node(), .args = payload.list() } };
        },
        .struct_literal => .{ .struct_literal = tree.listAt(data.extra) },
        .struct_field_init => .{ .struct_field_init = .{ .name_token = main, .value = data.node } },
        .error_value => .{ .error_value = main },

        .try_expr => .{ .try_expr = data.node },
        .orelse_expr => .{ .orelse_expr = .{
            .lhs = data.node_and_node[0],
            .rhs = data.node_and_node[1],
        } },
        .catch_expr => blk: {
            var payload = tree.fields(data.extra);
            break :blk .{ .catch_expr = .{
                .lhs = payload.node(),
                .capture = payload.optNode(),
                .rhs = payload.node(),
            } };
        },
        .binary => .{
            .binary = .{
                // `.binary` is only built for tokens the table names an operator for
                .op = oper_table[@intFromEnum(tree.tokenTag(main))].op.?,
                .op_token = main,
                .lhs = data.node_and_node[0],
                .rhs = data.node_and_node[1],
            },
        },
        .unary => .{ .unary = .{
            .op = unary_table[@intFromEnum(tree.tokenTag(main))].?,
            .op_token = main,
            .operand = data.node,
        } },
        .grouped => .{ .grouped = data.node },

        .pointer_type => .{ .pointer_type = .{
            .is_mutable = tree.tokenTag(main.after(1)) == .kw_var,
            .child = data.node,
        } },
        .optional_type => .{ .optional_type = data.node },
        .error_union_type => .{ .error_union_type = data.node },

        .err => .err,
    };
}

fn fields(tree: AST, start: ExtraIndex) Fields {
    assert(@intFromEnum(start) <= tree.extra.len);
    return .{ .extra = tree.extra, .cursor = @intFromEnum(start) };
}

fn listAt(tree: AST, start: ExtraIndex) []const Node.Index {
    var payload = tree.fields(start);
    return payload.list();
}

/// `pub` is always the token before the keyword a declaration is named by.
fn isPub(tree: AST, main: Token.Index) bool {
    assert(main.int() < tree.tokens.len);

    if (main == .first) return false;
    return tree.tokenTag(main.before(1)) == .kw_pub;
}

// nodes

pub fn nodeTag(tree: AST, node: Node.Index) Node.Tag {
    assert(node.int() < tree.nodes.len);
    return tree.nodes.items(.tag)[node.int()];
}

pub fn nodeMainToken(tree: AST, node: Node.Index) Token.Index {
    assert(node.int() < tree.nodes.len);
    return tree.nodes.items(.main_token)[node.int()];
}

/// The first of the run of doc comments above a declaration. Nothing is stored,
/// they sit in the token stream where they were typed.
pub fn docComment(tree: AST, decl: Node.Index) ?Token.Index {
    var first = tree.declStart(decl);
    if (first == .first) return null;
    if (tree.tokenTag(first.before(1)) != .doc_comment) return null;

    while (first != .first and tree.tokenTag(first.before(1)) == .doc_comment) {
        first = first.before(1);
    }

    assert(tree.tokenTag(first) == .doc_comment);
    return first;
}

/// Where a declaration begins, counting the `pub` it was written with.
fn declStart(tree: AST, node: Node.Index) Token.Index {
    assert(node.int() < tree.nodes.len);

    const main = tree.nodeMainToken(node);
    return if (tree.isPub(main)) main.before(1) else main;
}

// tokens

/// Past the last token reads as `.eof`. A derivation like "the token after this
/// one" can run off the end of a tree that failed to parse, and a wrong answer
/// beats a crash in a file already being rejected.
pub fn tokenTag(tree: AST, index: Token.Index) Token.Tag {
    const tags = tree.tokens.items(.tag);
    assert(tags.len > 0);
    if (index.int() < tags.len) return tags[index.int()];
    return .eof;
}

pub fn tokenStart(tree: AST, index: Token.Index) u32 {
    const starts = tree.tokens.items(.start);
    assert(starts.len > 0);
    if (index.int() < starts.len) return starts[index.int()];
    return @intCast(tree.source.len);
}

pub fn tokenEnd(tree: AST, index: Token.Index) u32 {
    const start = tree.tokenStart(index);
    assert(start <= tree.source.len);

    const end = Tokenizer.tokenEnd(tree.source, tree.tokenTag(index), start);
    // clamped, because a `.semi` inserted at the end of file has the length of
    // a `;` it does not occupy
    return @min(end, @as(u32, @intCast(tree.source.len)));
}

pub fn tokenSlice(tree: AST, index: Token.Index) []const u8 {
    const start = tree.tokenStart(index);
    const end = tree.tokenEnd(index);

    assert(start <= end);
    assert(end <= tree.source.len);
    return tree.source[start..end];
}

// spans, where a node is, for the carets

/// The extent of a node, from its leftmost token's start to its rightmost
/// child's end. Closing brackets are not counted, which a caret can bear.
pub fn nodeSpan(tree: AST, node: Node.Index) Diagnostic.Span {
    const first = edgeToken(tree, node, .leftmost);
    const last = edgeToken(tree, node, .rightmost);
    const start = tree.tokenStart(first);
    const end = tree.tokenEnd(last);
    if (start > end) {
        // a hole node can straddle repaired positions, so point at its start
        return .{ .start = start, .end = start };
    }
    return .{ .start = start, .end = end };
}

const Edgewise = enum { leftmost, rightmost };

/// Walk down one side of a node to the token that bounds it. Iterative, and
/// bounded by the walk always descending into a child.
fn edgeToken(tree: AST, node: Node.Index, side: Edgewise) Token.Index {
    var current = node;
    var depth: u32 = 0;
    const depth_cap = 4096;

    while (depth < depth_cap) : (depth += 1) {
        const main = tree.nodeMainToken(current);
        switch (tree.viewOf(current)) {
            .root => return if (side == .leftmost) .first else main,
            .err, .type_param, .capture, .break_stmt, .continue_stmt => return main,
            .ident, .number_literal, .null_literal => return main,
            .bool_literal => |it| return it.token,
            .error_value => |token| {
                // the name token. the `error` keyword sits two before it
                return if (side == .leftmost) token.before(2) else token;
            },

            .use_decl => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.path,
            },
            .struct_decl => |it| switch (side) {
                .leftmost => return main,
                .rightmost => {
                    if (it.members.len > 0) {
                        current = it.members[it.members.len - 1];
                    } else return main.after(1);
                },
            },
            .type_decl => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.aliased,
            },
            .fn_decl => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.body,
            },
            .var_decl => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.init_expr,
            },
            .param, .field => |it| switch (side) {
                .leftmost => return it.name_token,
                .rightmost => current = it.type_expr,
            },
            .block => |children| switch (side) {
                .leftmost => return main,
                .rightmost => {
                    if (children.len > 0) {
                        current = children[children.len - 1];
                    } else return main.after(1);
                },
            },
            .assign, .orelse_expr => |it| {
                current = if (side == .leftmost) it.lhs else it.rhs;
            },
            .defer_stmt, .try_expr => |child| switch (side) {
                .leftmost => return main,
                .rightmost => current = child,
            },
            .if_stmt => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.else_node.unwrap() orelse it.then_block,
            },
            .while_stmt => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.body,
            },
            .return_stmt => |operand| switch (side) {
                .leftmost => return main,
                .rightmost => current = operand.unwrap() orelse return main,
            },
            .field_access => |it| switch (side) {
                .leftmost => current = it.lhs,
                .rightmost => return it.name_token,
            },
            .instance => |it| switch (side) {
                .leftmost => current = it.base,
                .rightmost => {
                    if (it.args.len > 0) {
                        current = it.args[it.args.len - 1];
                    } else return main;
                },
            },
            .call => |it| switch (side) {
                .leftmost => current = it.callee,
                .rightmost => {
                    if (it.args.len > 0) {
                        current = it.args[it.args.len - 1];
                    } else return main.after(1);
                },
            },
            .struct_literal => |children| switch (side) {
                .leftmost => return main,
                .rightmost => {
                    if (children.len > 0) {
                        current = children[children.len - 1];
                    } else return main.after(2);
                },
            },
            .struct_field_init => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.value,
            },
            .catch_expr => |it| {
                current = if (side == .leftmost) it.lhs else it.rhs;
            },
            .binary => |it| {
                current = if (side == .leftmost) it.lhs else it.rhs;
            },
            .unary => |it| switch (side) {
                .leftmost => return it.op_token,
                .rightmost => current = it.operand,
            },
            .grouped, .optional_type, .error_union_type => |child| switch (side) {
                .leftmost => return main,
                .rightmost => current = child,
            },
            .pointer_type => |it| switch (side) {
                .leftmost => return main,
                .rightmost => current = it.child,
            },
        }
    }
    return tree.nodeMainToken(current);
}
