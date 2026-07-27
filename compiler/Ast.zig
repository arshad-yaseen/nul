//! The syntax tree

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @import("Token.zig");
const Tokenizer = @import("Tokenizer.zig");
const Parse = @import("Parse.zig");

const Ast = @This();

/// Borrowed, the caller's `Source` must outlive the tree.
source: [:0]const u8,
tokens: Tokenizer.TokenList.Slice,
nodes: NodeList.Slice,
/// Variable-length children, referenced by `SubRange`. A node's children appear here
/// in source order.
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
    /// The token that names this node, an operator, a declaration's keyword, a call's
    /// `(`. Every other position derives from it.
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

    /// `?Index` would be 8 bytes and blow the payload budget. Stealing one value out
    /// of the `u32` keeps it at 4 while still forcing an `unwrap()` at every use.
    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }
    };

    /// A contiguous run of children in `extra`.
    pub const SubRange = struct { start: ExtraIndex, end: ExtraIndex };

    pub const Tag = enum(u8) {
        root,
        use_decl,
        fn_decl,
        param,
        block,
        let_decl,
        var_decl,
        return_stmt,
        assign,
        call,
        field_access,
        grouped,
        /// `struct { name: T ... }`, `data` is `extra_range`: the fields.
        struct_type,
        /// `name: T` inside a struct. `main_token` is the name.
        field,
        /// `*T`. `main_token` is `*`, `data` is `node`: the pointee type.
        pointer_type,

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

        negate,
        bool_not,

        ident,
        int_literal,
        str_literal,
        true_literal,
        false_literal,

        err,
    };

    /// Eight bytes reinterpreted by `tag`. Only `full` reads this, everything else
    /// goes through the view.
    pub const Data = union {
        none: void,
        node: Index,
        opt_node: OptionalIndex,
        node_and_node: struct { Index, Index },
        opt_node_and_node: struct { OptionalIndex, Index },
        extra_range: SubRange,
    };
};

comptime {
    assert(@sizeOf(Node.Tag) == 1);

    if (!std.debug.runtime_safety) assert(@sizeOf(Node.Data) == 8);

    assertPositionIndependent(Node.Data);
}

fn assertPositionIndependent(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .bool, .void, .float, .@"enum" => {},
        .@"struct" => |s| for (s.fields) |f| assertPositionIndependent(f.type),
        .@"union" => |u| for (u.fields) |f| assertPositionIndependent(f.type),
        .array => |a| assertPositionIndependent(a.child),
        .pointer => @compileError(@typeName(T) ++ " is a pointer, use a u32 index"),
        .optional => @compileError(@typeName(T) ++ " is optional, use OptionalIndex"),
        else => @compileError("unsupported Ast payload: " ++ @typeName(T)),
    }
}

// The view

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

pub const UnaryOp = enum { negate, bool_not };

/// A node widened into named fields. Materialized on demand, never stored.
pub const Full = union(enum) {
    root: []const Node.Index,
    block: []const Node.Index,
    struct_type: []const Node.Index,
    use_decl: Node.Index,
    grouped: Node.Index,
    pointer_type: Pointer,
    return_stmt: Node.OptionalIndex,

    fn_decl: FnDecl,
    /// Both `let` and `var`, `is_mutable` distinguishes them.
    var_decl: VarDecl,
    call: Call,
    binary: Binary,
    unary: Unary,
    /// A name bound to a type. Same shape in both places.
    param: Binding,
    field: Binding,
    field_access: struct { lhs: Node.Index, name_token: TokenIndex },
    assign: struct { lhs: Node.Index, rhs: Node.Index },

    ident: TokenIndex,
    int_literal: TokenIndex,
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
        type_expr: Node.OptionalIndex,
        init_expr: Node.Index,
    };
    /// `*T` reads, `*var T` writes. Mutability is a token, never a stored bit.
    pub const Pointer = struct { is_mutable: bool, child: Node.Index };
    pub const Binding = struct { name_token: TokenIndex, type_expr: Node.Index };
    pub const Call = struct { callee: Node.Index, args: []const Node.Index };
    pub const Binary = struct { op: BinaryOp, op_token: TokenIndex, lhs: Node.Index, rhs: Node.Index };
    pub const Unary = struct { op: UnaryOp, op_token: TokenIndex, operand: Node.Index };
};

pub fn full(tree: Ast, n: Node.Index) Full {
    const main = tree.nodeMainToken(n);
    const data = tree.nodes.items(.data)[@intFromEnum(n)];
    return switch (tree.nodeTag(n)) {
        .root => .{ .root = tree.list(data.extra_range) },
        // Both of these park their `}` at the end of the range, see `lastToken`.
        .block => .{ .block = tree.listExceptLast(data.extra_range) },
        .struct_type => .{ .struct_type = tree.listExceptLast(data.extra_range) },
        .use_decl => .{ .use_decl = data.node },
        .grouped => .{ .grouped = data.node },
        .pointer_type => .{ .pointer_type = .{
            .is_mutable = tree.tokenTag(main + 1) == .kw_var,
            .child = data.node,
        } },
        .return_stmt => .{ .return_stmt = data.opt_node },
        .err => .err,

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

        inline .let_decl, .var_decl => |t| .{ .var_decl = .{
            .name_token = main + 1,
            .is_mutable = t == .var_decl,
            .type_expr = data.opt_node_and_node[0],
            .init_expr = data.opt_node_and_node[1],
        } },

        inline .add,
        .sub,
        .mul,
        .div,
        .mod,
        .equal,
        .not_equal,
        .less_than,
        .less_or_equal,
        .greater_than,
        .greater_or_equal,
        .bool_and,
        .bool_or,
        => |t| .{ .binary = .{
            .op = @field(BinaryOp, @tagName(t)),
            .op_token = main,
            .lhs = data.node_and_node[0],
            .rhs = data.node_and_node[1],
        } },

        inline .negate, .bool_not => |t| .{ .unary = .{
            .op = @field(UnaryOp, @tagName(t)),
            .op_token = main,
            .operand = data.node,
        } },

        .ident => .{ .ident = main },
        .int_literal => .{ .int_literal = main },
        .str_literal => .{ .str_literal = main },
        .true_literal => .{ .bool_literal = .{ .value = true, .token = main } },
        .false_literal => .{ .bool_literal = .{ .value = false, .token = main } },
    };
}

fn list(tree: Ast, range: Node.SubRange) []const Node.Index {
    return @ptrCast(tree.extra[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

/// For the ranges whose last entry is a trailing token rather than a child.
fn listExceptLast(tree: Ast, range: Node.SubRange) []const Node.Index {
    return @ptrCast(tree.extra[@intFromEnum(range.start) .. @intFromEnum(range.end) - 1]);
}

fn trailingToken(tree: Ast, range: Node.SubRange) TokenIndex {
    return tree.extra[@intFromEnum(range.end) - 1];
}

// Spans
//
// A diagnostic points at source, so every node has to be able to say where it
// starts and stops. Both walk to a leaf rather than storing anything, which keeps
// `Node` at its size. Callers are `Sema` and later passes, never the parser.

pub const Span = struct { start: u32, end: u32 };

pub fn nodeSpan(tree: Ast, n: Node.Index) Span {
    return .{
        .start = tree.tokenStart(tree.firstToken(n)),
        .end = tree.tokenSpan(tree.lastToken(n)).end,
    };
}

pub fn tokenSpan(tree: Ast, i: TokenIndex) Span {
    const start = tree.tokenStart(i);
    return .{ .start = start, .end = Tokenizer.tokenEnd(tree.source, tree.tokenTag(i), start) };
}

pub fn firstToken(tree: Ast, n: Node.Index) TokenIndex {
    const main = tree.nodeMainToken(n);
    return switch (tree.full(n)) {
        .root => 0,
        .fn_decl => |f| if (f.is_pub) main - 1 else main,
        .assign => |a| tree.firstToken(a.lhs),
        .binary => |b| tree.firstToken(b.lhs),
        .call => |c| tree.firstToken(c.callee),
        .field_access => |f| tree.firstToken(f.lhs),

        .use_decl,
        .block,
        .struct_type,
        .grouped,
        .pointer_type,
        .return_stmt,
        .var_decl,
        .param,
        .field,
        .unary,
        .ident,
        .int_literal,
        .str_literal,
        .bool_literal,
        .err,
        => main,
    };
}

pub fn lastToken(tree: Ast, n: Node.Index) TokenIndex {
    const main = tree.nodeMainToken(n);
    const data = tree.nodes.items(.data)[@intFromEnum(n)];
    switch (tree.nodeTag(n)) {
        .root => {
            const children = tree.list(data.extra_range);
            return if (children.len == 0) 0 else tree.lastToken(children[children.len - 1]);
        },
        // These two recorded their `}`, because a trailing `;` sits between the last
        // child and the brace and there is no way to walk back over it.
        .block, .struct_type => return tree.trailingToken(data.extra_range),
        else => {},
    }
    return switch (tree.full(n)) {
        .use_decl => |child| tree.lastToken(child),
        .pointer_type => |p| tree.lastToken(p.child),
        .fn_decl => |f| tree.lastToken(f.body),
        .var_decl => |v| tree.lastToken(v.init_expr),
        .param, .field => |b| tree.lastToken(b.type_expr),
        .assign => |a| tree.lastToken(a.rhs),
        .binary => |b| tree.lastToken(b.rhs),
        .unary => |u| tree.lastToken(u.operand),
        .field_access => |f| f.name_token,
        .return_stmt => |o| if (o.unwrap()) |x| tree.lastToken(x) else main,
        .bool_literal => |b| b.token,
        .ident, .int_literal, .str_literal => |t| t,
        .err => main,

        // The closing bracket follows the last thing inside it, give or take the
        // trailing comma an argument list is allowed. That holds because `Sema` only
        // ever runs on a tree that parsed without errors.
        .grouped => |child| tree.lastToken(child) + 1,
        .call => |c| blk: {
            const inner = if (c.args.len == 0) c.callee else c.args[c.args.len - 1];
            const after = tree.lastToken(inner) + 1;
            break :blk if (tree.tokenTag(after) == .comma) after + 1 else after;
        },

        .root, .block, .struct_type => unreachable, // handled above
    };
}

// Access

pub fn nodeTag(tree: Ast, n: Node.Index) Node.Tag {
    return tree.nodes.items(.tag)[@intFromEnum(n)];
}

pub fn nodeMainToken(tree: Ast, n: Node.Index) TokenIndex {
    return tree.nodes.items(.main_token)[@intFromEnum(n)];
}

pub fn tokenTag(tree: Ast, i: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[i];
}

pub fn tokenStart(tree: Ast, i: TokenIndex) u32 {
    return tree.tokens.items(.start)[i];
}

/// The source text of a token.
pub fn tokenSlice(tree: Ast, i: TokenIndex) []const u8 {
    const tag = tree.tokenTag(i);
    const start = tree.tokenStart(i);
    return tree.source[start..Tokenizer.tokenEnd(tree.source, tag, start)];
}

// Errors

pub const Error = struct {
    tag: Tag,
    /// The token the parser was looking at when it gave up.
    token: TokenIndex,
    expected: ?Token.Tag = null,

    pub const Tag = enum {
        expected_token,
        expected_expr,
        expected_statement,
        expected_top_level_decl,
        expected_param,
        expected_field,
        chained_comparison,
        invalid_assign_target,
        nesting_too_deep,
        invalid_bytes,
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
        }
    }
};
