//! Reads Markdown into a `ir.Text`.
//!
//! Markdown is the markup an author writes in a Zig doc comment, and the dialect read here
//! is the one Zig's own documentation generator reads: the parser under `markdown/` is the
//! one it ships, unchanged. Everything that parser recognizes has a place in the tree, so
//! nothing of the text is kept as markup. The alignment of table columns is the one thing
//! dropped.
//!
//! A code span whose content has the shape of a name, which is one identifier or several
//! joined by a dot or by `::`, optionally followed by `()`, is read as a mention of a symbol
//! and becomes an `ir.Ref` with no target. Any other code span is plain code.

const std = @import("std");
const ir = @import("ir.zig");
const Parser = @import("markdown/Parser.zig");
const Document = @import("markdown/Document.zig");

const Allocator = std.mem.Allocator;
const Node = Document.Node;

/// Parses `source`, whose lines end in `\n`, into a text allocated in `arena`.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!ir.Text {
    if (std.mem.trim(u8, source, " \t\r\n").len == 0) return .{};
    var parser: Parser = try .init(arena);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| try parser.feedLine(std.mem.trimEnd(u8, line, "\r"));
    const document = try parser.endInput();
    const reader: Reader = .{ .arena = arena, .document = document };
    return .{ .blocks = try reader.blocks(.root) };
}

/// Whether `span` has the shape of a name that can mention a symbol.
pub fn isName(span: []const u8) bool {
    const name = if (std.mem.endsWith(u8, span, "()")) span[0 .. span.len - 2] else span;
    if (name.len == 0) return false;
    var parts: Parts = .{ .rest = name };
    while (parts.next()) |part| {
        if (part.len == 0 or std.ascii.isDigit(part[0])) return false;
        for (part) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        }
    }
    return true;
}

/// The identifiers of a name, which a dot or `::` separates.
pub const Parts = struct {
    /// What is left of the name. Null once the last part was given.
    rest: ?[]const u8,

    /// The next identifier, or null after the last one.
    pub fn next(self: *Parts) ?[]const u8 {
        const rest = self.rest orelse return null;
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const colons = std.mem.indexOf(u8, rest, "::") orelse rest.len;
        if (dot == rest.len and colons == rest.len) {
            self.rest = null;
            return rest;
        }
        const width: usize = if (colons < dot) 2 else 1;
        const end = @min(dot, colons);
        self.rest = rest[end + width ..];
        return rest[0..end];
    }
};

const Reader = struct {
    arena: Allocator,
    document: Document,

    fn tag(self: Reader, node: Node.Index) Node.Tag {
        return self.document.nodes.items(.tag)[@intFromEnum(node)];
    }

    fn data(self: Reader, node: Node.Index) Node.Data {
        return self.document.nodes.items(.data)[@intFromEnum(node)];
    }

    fn children(self: Reader, node: Node.Index) []const Node.Index {
        const node_data = self.data(node);
        return self.document.extraChildren(switch (self.tag(node)) {
            .root, .table, .table_row, .blockquote, .paragraph, .strong, .emphasis => node_data.container.children,
            .list => node_data.list.children,
            .list_item => node_data.list_item.children,
            .table_cell => node_data.table_cell.children,
            .heading => node_data.heading.children,
            .link, .image => node_data.link.children,
            .code_block, .thematic_break, .autolink, .code_span, .text, .line_break => return &.{},
        });
    }

    fn string(self: Reader, index: Document.StringIndex) Allocator.Error![]const u8 {
        return self.arena.dupe(u8, self.document.string(index));
    }

    fn blocks(self: Reader, parent: Node.Index) Allocator.Error![]const ir.Block {
        var out: std.ArrayList(ir.Block) = .empty;
        for (self.children(parent)) |node| {
            const node_data = self.data(node);
            try out.append(self.arena, switch (self.tag(node)) {
                .paragraph => .{ .paragraph = try self.inlines(node) },
                .heading => .{ .heading = .{ .level = node_data.heading.level, .content = try self.inlines(node) } },
                .code_block => .{ .code = .{
                    .language = try self.string(node_data.code_block.tag),
                    .text = std.mem.trimEnd(u8, try self.string(node_data.code_block.content), "\n"),
                } },
                .list => .{ .list = try self.list(node) },
                .blockquote => .{ .quote = try self.blocks(node) },
                .table => .{ .table = try self.table(node) },
                .thematic_break => .rule,
                else => .{ .paragraph = try self.inlinesOf(&.{node}) },
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn list(self: Reader, node: Node.Index) Allocator.Error!ir.List {
        var items: std.ArrayList([]const ir.Block) = .empty;
        for (self.children(node)) |item| try items.append(self.arena, try self.blocks(item));
        const start: ?u32 = if (self.data(node).list.start.asNumber()) |number| number else null;
        return .{ .start = start, .items = try items.toOwnedSlice(self.arena) };
    }

    fn table(self: Reader, node: Node.Index) Allocator.Error!ir.Table {
        var header: []const []const ir.Inline = &.{};
        var rows: std.ArrayList([]const []const ir.Inline) = .empty;
        for (self.children(node)) |row| {
            var cells: std.ArrayList([]const ir.Inline) = .empty;
            var heading = false;
            for (self.children(row)) |cell| {
                if (self.data(cell).table_cell.info.header) heading = true;
                try cells.append(self.arena, try self.inlines(cell));
            }
            if (heading and header.len == 0) {
                header = try cells.toOwnedSlice(self.arena);
            } else {
                try rows.append(self.arena, try cells.toOwnedSlice(self.arena));
            }
        }
        return .{ .header = header, .rows = try rows.toOwnedSlice(self.arena) };
    }

    fn inlines(self: Reader, parent: Node.Index) Allocator.Error![]const ir.Inline {
        return self.inlinesOf(self.children(parent));
    }

    fn inlinesOf(self: Reader, nodes: []const Node.Index) Allocator.Error![]const ir.Inline {
        var out: std.ArrayList(ir.Inline) = .empty;
        for (nodes) |node| {
            const node_data = self.data(node);
            switch (self.tag(node)) {
                .text => {
                    const content = try self.string(node_data.text.content);
                    if (out.items.len != 0 and out.items[out.items.len - 1] == .text) {
                        const last = &out.items[out.items.len - 1];
                        last.* = .{ .text = try std.mem.concat(self.arena, u8, &.{ last.text, content }) };
                    } else {
                        try out.append(self.arena, .{ .text = content });
                    }
                },
                .code_span => {
                    const content = try self.string(node_data.text.content);
                    try out.append(self.arena, if (isName(content)) .{ .ref = .{ .text = content } } else .{ .code = content });
                },
                .emphasis => try out.append(self.arena, .{ .emphasis = try self.inlines(node) }),
                .strong => try out.append(self.arena, .{ .strong = try self.inlines(node) }),
                .link => try out.append(self.arena, .{ .link = .{ .url = try self.string(node_data.link.target), .content = try self.inlines(node) } }),
                .image => try out.append(self.arena, .{ .image = .{ .url = try self.string(node_data.link.target), .content = try self.inlines(node) } }),
                .autolink => {
                    const url = try self.string(node_data.text.content);
                    try out.append(self.arena, .{ .link = .{ .url = url, .content = try self.arena.dupe(ir.Inline, &.{.{ .text = url }}) } });
                },
                .line_break => try out.append(self.arena, .line_break),
                else => {},
            }
        }
        return out.toOwnedSlice(self.arena);
    }
};

fn parsed(arena: *std.heap.ArenaAllocator, source: []const u8) ![]const ir.Block {
    return (try parse(arena.allocator(), source)).blocks;
}

test "a paragraph keeps its words, its stress and its links, and a name in backticks mentions a symbol" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try parsed(&arena, "Calls `Pool.wait()` with *care*, never `a + b`.\nSee [the site](https://example.org) and **this**.");
    try std.testing.expectEqualDeep(@as([]const ir.Block, &.{.{ .paragraph = &.{
        .{ .text = "Calls " },
        .{ .ref = .{ .text = "Pool.wait()" } },
        .{ .text = " with " },
        .{ .emphasis = &.{.{ .text = "care" }} },
        .{ .text = ", never " },
        .{ .code = "a + b" },
        .{ .text = ".\nSee " },
        .{ .link = .{ .url = "https://example.org", .content = &.{.{ .text = "the site" }} } },
        .{ .text = " and " },
        .{ .strong = &.{.{ .text = "this" }} },
        .{ .text = "." },
    } }}), blocks);
}

test "blocks are told apart: heading, code, lists, quote, table and rule" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try parsed(&arena,
        \\# Title
        \\
        \\```zig
        \\const a = `not a span`;
        \\```
        \\
        \\- one
        \\- two
        \\
        \\3. three
        \\
        \\> quoted
        \\
        \\| name | use |
        \\|---|---|
        \\| `wait` | blocks |
        \\
        \\---
    );
    try std.testing.expectEqual(7, blocks.len);
    try std.testing.expectEqualDeep(ir.Block{ .heading = .{ .level = 1, .content = &.{.{ .text = "Title" }} } }, blocks[0]);
    try std.testing.expectEqualDeep(ir.Block{ .code = .{ .language = "zig", .text = "const a = `not a span`;" } }, blocks[1]);
    try std.testing.expectEqual(null, blocks[2].list.start);
    try std.testing.expectEqual(2, blocks[2].list.items.len);
    try std.testing.expectEqualDeep(@as([]const ir.Block, &.{.{ .paragraph = &.{.{ .text = "two" }} }}), blocks[2].list.items[1]);
    try std.testing.expectEqual(3, blocks[3].list.start.?);
    try std.testing.expectEqualDeep(@as([]const ir.Block, &.{.{ .paragraph = &.{.{ .text = "quoted" }} }}), blocks[4].quote);
    try std.testing.expectEqualDeep(ir.Table{
        .header = &.{ &.{.{ .text = "name" }}, &.{.{ .text = "use" }} },
        .rows = &.{&.{ &.{.{ .ref = .{ .text = "wait" } }}, &.{.{ .text = "blocks" }} }},
    }, blocks[5].table);
    try std.testing.expectEqual(ir.Block.rule, blocks[6]);
}

test "text with nothing in it has no blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(0, (try parsed(&arena, " \n\n")).len);
}

test "the shape of a name" {
    try std.testing.expect(isName("wait"));
    try std.testing.expect(isName("std.mem.Allocator"));
    try std.testing.expect(isName("Pool.wait()"));
    try std.testing.expect(isName("ke::Pool::wait()"));
    try std.testing.expect(!isName("ke:Pool"));
    try std.testing.expect(!isName("::Pool"));
    try std.testing.expect(!isName("a + b"));
    try std.testing.expect(!isName("--out"));
    try std.testing.expect(!isName("3d"));
    try std.testing.expect(!isName("a..b"));
}
