//! Finds the symbols of a document that a name asks for.
//!
//! A name is looked for three ways, and the first that finds anything answers. It is first
//! taken as an identifier or a qualified name, written in full. Then as the end of a
//! qualified name: "Pool.wait" finds "ke.Pool.wait", and "wait" finds every symbol of that
//! name, whichever separator its language writes between the parts. Last, as a piece of a
//! name, without regard to case, which is what answers a name that is only half remembered.
//!
//! `search` looks in what the documentation says and not in the names: it answers every
//! symbol with a paragraph that holds all the words asked for, without regard to case, and
//! that paragraph with it. It is what answers a question about an idea that no symbol is
//! named after.
//!
//! `roots` answers what a document holds before any name is known: its documented files
//! and its namespaces.
//!
//! A namespace declared in several files is in the document once for each of them. It is
//! answered once, with what all of them declare in it.

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
        if (found.items.len != 0) return united(arena, found.items);
    }
    return &.{};
}

fn united(arena: Allocator, list: []const ir.Symbol) Allocator.Error![]const ir.Symbol {
    var out: std.ArrayList(ir.Symbol) = .empty;
    next: for (list) |symbol| {
        if (symbol.kind == .namespace) {
            for (out.items) |*known| {
                if (known.kind != .namespace or !std.mem.eql(u8, known.qualified_name, symbol.qualified_name)) continue;
                if (!std.mem.eql(u8, languageOf(known.id), languageOf(symbol.id))) continue;
                known.locations = try std.mem.concat(arena, ir.Location, &.{ known.locations, symbol.locations });
                known.members = try std.mem.concat(arena, ir.Symbol, &.{ known.members, symbol.members });
                if (known.doc.isEmpty()) known.doc = symbol.doc;
                continue :next;
            }
        }
        try out.append(arena, symbol);
    }
    for (out.items) |*symbol| {
        if (symbol.kind == .namespace) symbol.members = try united(arena, symbol.members);
    }
    return out.toOwnedSlice(arena);
}

fn languageOf(id: []const u8) []const u8 {
    return id[0 .. std.mem.indexOfScalar(u8, id, ':') orelse id.len];
}

/// A symbol whose documentation holds the words asked for.
pub const Hit = struct {
    /// The symbol.
    symbol: ir.Symbol,
    /// The first paragraph of its documentation that holds every word, as plain text.
    paragraph: []const u8,
};

/// The symbols of `document` with a paragraph of documentation that holds every one of
/// `words`, which are separated by spaces, in the order of the document.
pub fn search(arena: Allocator, document: ir.Document, words: []const u8) Allocator.Error![]const Hit {
    var wanted: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.tokenizeAny(u8, words, " \t\n");
    while (parts.next()) |part| try wanted.append(arena, part);
    var hits: std.ArrayList(Hit) = .empty;
    if (wanted.items.len != 0) try searchIn(arena, document.symbols, wanted.items, &hits);
    return hits.toOwnedSlice(arena);
}

fn searchIn(arena: Allocator, list: []const ir.Symbol, wanted: []const []const u8, hits: *std.ArrayList(Hit)) Allocator.Error!void {
    for (list) |symbol| {
        if (try saidBy(arena, symbol, wanted)) |paragraph| try hits.append(arena, .{ .symbol = symbol, .paragraph = paragraph });
        try searchIn(arena, symbol.members, wanted, hits);
    }
}

fn saidBy(arena: Allocator, symbol: ir.Symbol, wanted: []const []const u8) Allocator.Error!?[]const u8 {
    if (try saidIn(arena, symbol.doc, wanted)) |paragraph| return paragraph;
    for (symbol.params) |param| {
        if (try saidIn(arena, param.doc, wanted)) |paragraph| return paragraph;
    }
    if (try saidIn(arena, symbol.returns, wanted)) |paragraph| return paragraph;
    for (symbol.raises) |raised| {
        if (try saidIn(arena, raised.doc, wanted)) |paragraph| return paragraph;
    }
    return null;
}

fn saidIn(arena: Allocator, text: ir.Text, wanted: []const []const u8) Allocator.Error!?[]const u8 {
    next: for (text.blocks) |block| {
        const paragraph = try ir.plainText(arena, .{ .blocks = &.{block} });
        for (wanted) |word| {
            if (std.ascii.indexOfIgnoreCase(paragraph, word) == null) continue :next;
        }
        return paragraph;
    }
    return null;
}

/// What `document` holds at the top: each documented file that says or declares something
/// itself, in the order of the document, then each namespace that declares something, once
/// and in the order of the names.
pub fn roots(arena: Allocator, document: ir.Document) Allocator.Error![]const ir.Symbol {
    var out: std.ArrayList(ir.Symbol) = .empty;
    var spaces: std.ArrayList(ir.Symbol) = .empty;
    const count = @min(document.files.len, document.symbols.len);
    for (document.files[0..count], document.symbols[0..count]) |file, root| {
        if (!file.documented) continue;
        if (!root.doc.isEmpty() or holdsDeclarations(root)) try out.append(arena, root);
        try spacesIn(arena, root.members, &spaces);
    }
    const joined = try arena.dupe(ir.Symbol, try united(arena, spaces.items));
    std.mem.sort(ir.Symbol, joined, {}, struct {
        fn before(_: void, a: ir.Symbol, b: ir.Symbol) bool {
            return std.mem.lessThan(u8, a.qualified_name, b.qualified_name);
        }
    }.before);
    try out.appendSlice(arena, joined);
    return out.toOwnedSlice(arena);
}

fn holdsDeclarations(symbol: ir.Symbol) bool {
    for (symbol.members) |member| {
        if (member.kind != .namespace) return true;
    }
    return false;
}

fn spacesIn(arena: Allocator, list: []const ir.Symbol, spaces: *std.ArrayList(ir.Symbol)) Allocator.Error!void {
    for (list) |symbol| {
        if (symbol.kind != .namespace) continue;
        if (holdsDeclarations(symbol)) {
            var own = symbol;
            var kept: std.ArrayList(ir.Symbol) = .empty;
            for (symbol.members) |member| {
                if (member.kind != .namespace) try kept.append(arena, member);
            }
            own.members = try kept.toOwnedSlice(arena);
            try spaces.append(arena, own);
        }
        try spacesIn(arena, symbol.members, spaces);
    }
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

test "a namespace declared in several files is answered once, with the members of all" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const document: ir.Document = .{ .symbols = &.{
        .{ .id = "csharp:A.cs", .name = "A", .qualified_name = "A.cs", .kind = .module, .members = &.{.{
            .id = "csharp:A.cs#Ke",
            .name = "Ke",
            .qualified_name = "Ke",
            .kind = .namespace,
            .locations = &.{.{ .file = "A.cs", .line = 1 }},
            .members = &.{.{ .id = "csharp:A.cs#Ke.Pool", .name = "Pool", .qualified_name = "Ke.Pool", .kind = .type }},
        }} },
        .{ .id = "csharp:B.cs", .name = "B", .qualified_name = "B.cs", .kind = .module, .members = &.{.{
            .id = "csharp:B.cs#Ke",
            .name = "Ke",
            .qualified_name = "Ke",
            .kind = .namespace,
            .locations = &.{.{ .file = "B.cs", .line = 1 }},
            .members = &.{.{ .id = "csharp:B.cs#Ke.Task", .name = "Task", .qualified_name = "Ke.Task", .kind = .type }},
        }} },
    } };
    const found = try find(arena.allocator(), document, "Ke");
    try std.testing.expectEqual(1, found.len);
    try std.testing.expectEqual(2, found[0].locations.len);
    try std.testing.expectEqual(2, found[0].members.len);
    try std.testing.expectEqualStrings("Task", found[0].members[1].name);
}

test "a search answers the symbols whose documentation holds every word, with the paragraph" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const document: ir.Document = .{ .symbols = &.{.{
        .id = "zig:a.zig",
        .name = "a",
        .qualified_name = "a.zig",
        .kind = .module,
        .doc = .{ .blocks = &.{
            .{ .paragraph = &.{.{ .text = "Runs the bodies of a wave." }} },
            .{ .paragraph = &.{.{ .text = "Structural changes are applied after the Wave ends." }} },
        } },
        .members = &.{
            .{ .id = "zig:a.zig#flush", .name = "flush", .qualified_name = "flush", .kind = .function, .returns = .{ .blocks = &.{.{ .paragraph = &.{.{ .text = "False when the changes of the wave fail." }} }} } },
            .{ .id = "zig:a.zig#wave", .name = "wave", .qualified_name = "wave", .kind = .function },
        },
    }} };
    const hits = try search(arena.allocator(), document, "wave changes");
    try std.testing.expectEqual(2, hits.len);
    try std.testing.expectEqualStrings("a.zig", hits[0].symbol.qualified_name);
    try std.testing.expectEqualStrings("Structural changes are applied after the Wave ends.", hits[0].paragraph);
    try std.testing.expectEqualStrings("flush", hits[1].symbol.name);
    try std.testing.expectEqual(0, (try search(arena.allocator(), document, "nothing")).len);
    try std.testing.expectEqual(0, (try search(arena.allocator(), document, " ")).len);
}

test "the roots of a document are its files that declare something and its namespaces, once each" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pool: ir.Symbol = .{ .id = "csharp:A.cs#Ke.Run.Pool", .name = "Pool", .qualified_name = "Ke.Run.Pool", .kind = .type };
    const inner: ir.Symbol = .{ .id = "csharp:A.cs#Ke.Run", .name = "Run", .qualified_name = "Ke.Run", .kind = .namespace, .members = &.{pool} };
    const outer: ir.Symbol = .{ .id = "csharp:A.cs#Ke", .name = "Ke", .qualified_name = "Ke", .kind = .namespace, .members = &.{inner} };
    const document: ir.Document = .{
        .files = &.{ .{ .path = "A.cs", .language = "csharp" }, .{ .path = "B.cs", .language = "csharp" }, .{ .path = "a.zig", .language = "zig" }, .{ .path = "b.zig", .language = "zig", .documented = false } },
        .symbols = &.{
            .{ .id = "csharp:A.cs", .name = "A", .qualified_name = "A.cs", .kind = .module, .members = &.{outer} },
            .{ .id = "csharp:B.cs", .name = "B", .qualified_name = "B.cs", .kind = .module, .members = &.{outer} },
            .{ .id = "zig:a.zig", .name = "a", .qualified_name = "a.zig", .kind = .module, .members = &.{.{ .id = "zig:a.zig#run", .name = "run", .qualified_name = "run", .kind = .function }} },
            .{ .id = "zig:b.zig", .name = "b", .qualified_name = "b.zig", .kind = .module, .members = &.{.{ .id = "zig:b.zig#run", .name = "run", .qualified_name = "run", .kind = .function }} },
        },
    };
    const found = try roots(arena.allocator(), document);
    try std.testing.expectEqual(2, found.len);
    try std.testing.expectEqualStrings("a.zig", found[0].qualified_name);
    try std.testing.expectEqualStrings("Ke.Run", found[1].qualified_name);
    try std.testing.expectEqual(2, found[1].members.len);
}
