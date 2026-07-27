//! A semantic error, and the list a compilation accumulates. Every pass appends to one
//! list, so there is one sort and one renderer however many passes there are.
//!
//! Parse errors stay `Ast.Error`: they name an expected token and have their own shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");

const Error = @This();

tag: Tag,
token: Ast.TokenIndex,

pub const Tag = enum {
    redeclared,
    shadows_builtin,
    undefined_name,
    depends_on_itself,
    not_a_type,
    type_mismatch,
    unsupported_value,
    invalid_digit,
    literal_too_large,
};

pub fn render(err: Error, tree: *const Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const name = tree.tokenSlice(err.token);
    switch (err.tag) {
        .redeclared => try w.print("'{s}' is declared more than once", .{name}),
        .shadows_builtin => try w.print("'{s}' is a builtin type", .{name}),
        .undefined_name => try w.print("no declaration named '{s}'", .{name}),
        .depends_on_itself => try w.print("'{s}' depends on itself", .{name}),
        .not_a_type => try w.print("'{s}' is not a type", .{name}),
        .type_mismatch => try w.writeAll("the declared type does not match the value"),
        .unsupported_value => try w.writeAll(
            "evaluating this at compile time is not implemented yet",
        ),
        .invalid_digit => try w.print("'{s}' is not a valid number", .{name}),
        .literal_too_large => try w.print("'{s}' does not fit any integer type", .{name}),
    }
}

pub const List = struct {
    items: std.ArrayList(Error),

    pub const empty: List = .{ .items = .empty };

    pub fn deinit(list: *List, gpa: Allocator) void {
        list.items.deinit(gpa);
        list.* = undefined;
    }

    pub fn add(list: *List, gpa: Allocator, err: Error) Allocator.Error!void {
        @branchHint(.cold);
        try list.items.append(gpa, err);
    }

    pub fn all(list: *const List) []const Error {
        return list.items.items;
    }

    /// Collection reports before resolution, and resolution follows dependencies rather
    /// than the file, so neither order is the reader's.
    pub fn sortBySource(list: *List) void {
        std.mem.sort(Error, list.items.items, {}, struct {
            fn before(_: void, a: Error, b: Error) bool {
                return a.token < b.token;
            }
        }.before);
    }
};
