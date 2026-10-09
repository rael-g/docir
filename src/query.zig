//! Finds the symbols of a document that a name asks for.
//!
//! A name is looked for three ways, and the first that finds anything answers. It is first
//! taken as an identifier or a qualified name, written in full. Then as the end of a
//! qualified name: "Pool.wait" finds "ke.Pool.wait", and "wait" finds every symbol of that
//! name, whichever separator its language writes between the parts. Last, as a piece of a
//! name, without regard to case, which is what answers a name that is only half remembered.

const std = @import("std");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;

/// The symbols of `document` that `name` asks for, in the order of the document. None when
/// no name holds it.
pub fn find(arena: Allocator, document: ir.Document, name: []const u8) Allocator.Error![]const ir.Symbol {
    if (name.len == 0) return &.{};
    for ([_]Match{ .whole, .end, .piece }) |match| {
        var found: std.ArrayList(ir.Symbol) = .empty;
        try collect(arena, document.symbols, name, match, &found);
        if (found.items.len != 0) return found.toOwnedSlice(arena);
    }
    return &.{};
}

const Match = enum { whole, end, piece };

fn collect(arena: Allocator, list: []const ir.Symbol, name: []const u8, match: Match, found: *std.ArrayList(ir.Symbol)) Allocator.Error!void {
    for (list) |symbol| {
        const qualified = symbol.qualified_name;
        const matches = switch (match) {
            .whole => std.mem.eql(u8, symbol.id, name) or std.mem.eql(u8, qualified, name),
            .end => std.mem.endsWith(u8, qualified, name) and qualified.len > name.len and isSeparator(qualified[qualified.len - name.len - 1]),
            .piece => std.ascii.indexOfIgnoreCase(qualified, name) != null,
        };
        if (matches) try found.append(arena, symbol);
        try collect(arena, symbol.members, name, match, found);
    }
}

fn isSeparator(ch: u8) bool {
    return ch == '.' or ch == ':' or ch == '/';
}

test "a name is found in full, then as the end of a qualified name, then as a piece of one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const document: ir.Document = .{ .symbols = &.{.{
        .id = "cpp:pool.hpp",
        .name = "pool",
        .qualified_name = "pool.hpp",
        .kind = .module,
        .members = &.{.{
            .id = "cpp:pool.hpp#ke::Pool",
            .name = "Pool",
            .qualified_name = "ke::Pool",
            .kind = .type,
            .members = &.{
                .{ .id = "cpp:pool.hpp#ke::Pool::wait", .name = "wait", .qualified_name = "ke::Pool::wait", .kind = .function },
                .{ .id = "cpp:pool.hpp#ke::Pool::waiting", .name = "waiting", .qualified_name = "ke::Pool::waiting", .kind = .field },
            },
        }},
    }} };
    const whole = try find(arena.allocator(), document, "ke::Pool");
    try std.testing.expectEqual(1, whole.len);
    try std.testing.expectEqualStrings("Pool", whole[0].name);
    const end = try find(arena.allocator(), document, "Pool::wait");
    try std.testing.expectEqual(1, end.len);
    try std.testing.expectEqualStrings("wait", end[0].name);
    try std.testing.expectEqual(2, (try find(arena.allocator(), document, "WAIT")).len);
    try std.testing.expectEqual(0, (try find(arena.allocator(), document, "stop")).len);
}
