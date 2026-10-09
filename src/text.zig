//! Writes a document, or one symbol of it, as plain text for a terminal.
//!
//! Nothing here is markup: the text is meant to be read as it is printed. A symbol opens
//! with its qualified name on a line of its own, followed by what it is and where it is
//! declared, its signature, and its documentation indented under them, with paragraphs
//! broken at `Options.width` columns. Code keeps its lines. A mention, a parameter and code
//! inside a line are set between grave accents, and a link is followed by its address
//! between parentheses.
//!
//! `write` prints every symbol of the documented files that `ir.Symbol.hasDocumentation`,
//! which is what the Markdown writer gives a section to. `writeSymbol` prints one symbol in
//! full, whether it is documented or not, and closes it with one line per member, so that
//! what is inside it can be asked for next.

const std = @import("std");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What writing can fail with: the arena or the writer.
pub const Error = Allocator.Error || Writer.Error;

/// How the text is laid out.
pub const Options = struct {
    /// The column a paragraph is broken before.
    width: usize = 80,
};

const indent = "    ";

/// Prints `title`, then every documented symbol of the documented files of `document`.
pub fn write(arena: Allocator, writer: *Writer, title: []const u8, document: ir.Document, options: Options) Error!void {
    const printer: Printer = .{ .arena = arena, .writer = writer, .width = options.width };
    try writer.print("{s}\n", .{title});
    try writer.splatByteAll('=', title.len);
    try writer.writeByte('\n');
    const count = @min(document.files.len, document.symbols.len);
    for (document.files[0..count], document.symbols[0..count]) |file, root| {
        if (!file.documented or !root.hasDocumentation()) continue;
        if (!root.doc.isEmpty()) {
            try writer.print("\n{s}\n", .{root.qualified_name});
            try printer.blocks(root.doc.blocks, indent);
        }
        for (root.members) |member| try printer.all(member);
    }
}

/// Prints `symbol` in full and one line for each of its members.
pub fn writeSymbol(arena: Allocator, writer: *Writer, symbol: ir.Symbol, options: Options) Error!void {
    const printer: Printer = .{ .arena = arena, .writer = writer, .width = options.width };
    try printer.symbol(symbol);
    if (symbol.members.len == 0) return;
    try writer.print("\n{s}Members:\n", .{indent});
    var longest: usize = 0;
    for (symbol.members) |member| longest = @max(longest, member.name.len);
    for (symbol.members) |member| {
        try writer.print("{s}  {s}", .{ indent, member.name });
        try writer.splatByteAll(' ', longest - member.name.len + 2);
        try writer.writeAll(if (member.form.len != 0) member.form else @tagName(member.kind));
        const said = try printer.sentence(member.doc);
        if (said.len != 0) try writer.print("  {s}", .{said});
        try writer.writeByte('\n');
    }
}

const Printer = struct {
    arena: Allocator,
    writer: *Writer,
    width: usize,

    fn all(self: Printer, found: ir.Symbol) Error!void {
        if (!found.hasDocumentation()) return;
        const transparent = found.kind == .namespace and found.doc.isEmpty();
        if (!transparent) {
            try self.writer.writeByte('\n');
            try self.symbol(found);
        }
        for (found.members) |member| try self.all(member);
    }

    fn symbol(self: Printer, found: ir.Symbol) Error!void {
        const writer = self.writer;
        try writer.print("{s}\n{s}", .{ found.qualified_name, indent });
        if (found.form.len != 0) try writer.print("{s}, ", .{found.form}) else try writer.print("{t}, ", .{found.kind});
        try writer.print("{t}", .{found.visibility});
        for (found.modifiers) |modifier| try writer.print(", {s}", .{modifier});
        for (found.locations) |location| try writer.print(", {s}:{d}", .{ location.file, location.line });
        try writer.writeByte('\n');
        if (found.signature.len != 0) {
            try writer.writeByte('\n');
            try self.verbatim(found.signature, indent);
        }
        if (found.bases.len != 0) {
            try writer.print("\n{s}Derives from:", .{indent});
            for (found.bases, 0..) |base, index| try writer.print("{s} {s}", .{ if (index == 0) "" else ",", base.text });
            try writer.writeByte('\n');
        }
        if (!found.doc.isEmpty()) try self.blocks(found.doc.blocks, indent);

        var open = false;
        for (found.type_params) |param| {
            if (param.doc.isEmpty()) continue;
            if (!open) try writer.print("\n{s}Type parameters:\n", .{indent});
            open = true;
            try self.entry(param.name, param.constraint, param.doc);
        }
        open = false;
        for (found.params) |param| {
            if (param.doc.isEmpty()) continue;
            if (!open) try writer.print("\n{s}Parameters:\n", .{indent});
            open = true;
            try self.entry(param.name, param.type.text, param.doc);
        }
        if (!found.returns.isEmpty()) {
            try writer.print("\n{s}Returns:\n", .{indent});
            try self.blocksTight(found.returns.blocks, indent ++ "  ");
        }
        open = false;
        for (found.raises) |raised| {
            if (raised.doc.isEmpty()) continue;
            if (!open) try writer.print("\n{s}Raises:\n", .{indent});
            open = true;
            try self.entry(raised.type.text, "", raised.doc);
        }
        for (found.examples) |example| {
            try writer.print("\n{s}Example:\n", .{indent});
            try self.verbatim(example.code, indent ++ "  ");
        }
    }

    fn entry(self: Printer, name: []const u8, written_type: []const u8, said: ir.Text) Error!void {
        const head = if (written_type.len == 0)
            try std.fmt.allocPrint(self.arena, "{s}  {s}", .{ indent, name })
        else
            try std.fmt.allocPrint(self.arena, "{s}  {s} ({s})", .{ indent, name, written_type });
        try self.writer.print("{s}\n", .{head});
        try self.blocksTight(said.blocks, indent ++ indent);
    }

    fn verbatim(self: Printer, code: []const u8, margin: []const u8) Error!void {
        var lines = std.mem.splitScalar(u8, code, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) try self.writer.writeByte('\n') else try self.writer.print("{s}{s}\n", .{ margin, line });
        }
    }

    fn blocks(self: Printer, list: []const ir.Block, margin: []const u8) Error!void {
        for (list) |each| {
            try self.writer.writeByte('\n');
            try self.block(each, margin);
        }
    }

    fn blocksTight(self: Printer, list: []const ir.Block, margin: []const u8) Error!void {
        for (list, 0..) |each, index| {
            if (index != 0) try self.writer.writeByte('\n');
            try self.block(each, margin);
        }
    }

    fn block(self: Printer, found: ir.Block, margin: []const u8) Error!void {
        switch (found) {
            .paragraph => |content| try self.wrapped(try self.plain(content), margin, margin),
            .heading => |heading| try self.wrapped(try self.plain(heading.content), margin, margin),
            .code => |code| try self.verbatim(code.text, try std.mem.concat(self.arena, u8, &.{ margin, indent })),
            .list => |list| for (list.items, 0..) |item, index| {
                const marker = if (list.start) |start| try std.fmt.allocPrint(self.arena, "{d}. ", .{start + index}) else "- ";
                const hanging = try self.arena.alloc(u8, margin.len + marker.len);
                @memset(hanging, ' ');
                for (item, 0..) |inner, position| {
                    if (position != 0) try self.writer.writeByte('\n');
                    if (position == 0 and inner == .paragraph) {
                        try self.wrapped(try self.plain(inner.paragraph), try std.mem.concat(self.arena, u8, &.{ margin, marker }), hanging);
                    } else try self.block(inner, hanging);
                }
            },
            .quote => |quoted| try self.blocksTight(quoted, try std.mem.concat(self.arena, u8, &.{ margin, "> " })),
            .note => |note| {
                var label = try self.arena.dupe(u8, note.label);
                if (label.len != 0) label[0] = std.ascii.toUpper(label[0]);
                try self.writer.print("{s}{s}:\n", .{ margin, label });
                try self.blocksTight(note.blocks, try std.mem.concat(self.arena, u8, &.{ margin, "  " }));
            },
            .table => |table| {
                if (table.header.len != 0) try self.row(table.header, margin);
                for (table.rows) |cells| try self.row(cells, margin);
            },
            .rule => {
                try self.writer.writeAll(margin);
                try self.writer.splatByteAll('-', self.width -| margin.len);
                try self.writer.writeByte('\n');
            },
        }
    }

    fn row(self: Printer, cells: []const []const ir.Inline, margin: []const u8) Error!void {
        try self.writer.writeAll(margin);
        for (cells, 0..) |cell, index| {
            if (index != 0) try self.writer.writeAll(" | ");
            try self.writer.writeAll(try self.plain(cell));
        }
        try self.writer.writeByte('\n');
    }

    fn wrapped(self: Printer, content: []const u8, first: []const u8, rest: []const u8) Error!void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var margin = first;
        while (lines.next()) |line| {
            var column: usize = 0;
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            while (words.next()) |word| {
                if (column == 0) {
                    try self.writer.writeAll(margin);
                    column = margin.len;
                } else if (column + 1 + word.len > self.width) {
                    try self.writer.print("\n{s}", .{rest});
                    column = rest.len;
                } else {
                    try self.writer.writeByte(' ');
                    column += 1;
                }
                try self.writer.writeAll(word);
                column += word.len;
                margin = rest;
            }
            try self.writer.writeByte('\n');
        }
    }

    fn plain(self: Printer, list: []const ir.Inline) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (list) |piece| switch (piece) {
            .text => |characters| for (characters) |ch| try out.append(self.arena, if (ch == '\n') ' ' else ch),
            .code, .param => |characters| try out.print(self.arena, "`{s}`", .{characters}),
            .ref => |ref| try out.print(self.arena, "`{s}`", .{ref.text}),
            .emphasis, .strong => |content| try out.appendSlice(self.arena, try self.plain(content)),
            .link => |link| try out.print(self.arena, "{s} ({s})", .{ try self.plain(link.content), link.url }),
            .image => |image| try out.print(self.arena, "{s} ({s})", .{ try self.plain(image.content), image.url }),
            .line_break => try out.append(self.arena, '\n'),
        };
        return out.toOwnedSlice(self.arena);
    }

    fn sentence(self: Printer, said: ir.Text) Error![]const u8 {
        for (said.blocks) |found| {
            if (found != .paragraph) continue;
            const whole = try self.plain(found.paragraph);
            const line = whole[0 .. std.mem.indexOfScalar(u8, whole, '\n') orelse whole.len];
            const end = if (std.mem.indexOf(u8, line, ". ")) |stop| stop + 1 else line.len;
            return line[0..end];
        }
        return "";
    }
};

const sample: ir.Symbol = .{
    .id = "c:a.h#pool",
    .name = "pool",
    .qualified_name = "pool",
    .kind = .type,
    .form = "struct",
    .locations = &.{.{ .file = "a.h", .line = 3 }},
    .signature = "typedef struct pool",
    .doc = .{ .blocks = &.{
        .{ .paragraph = &.{ .{ .text = "Runs tasks on a " }, .{ .ref = .{ .text = "worker" } }, .{ .text = " and never\non the caller, however long that takes." } } },
        .{ .list = .{ .items = &.{ &.{.{ .paragraph = &.{.{ .text = "one" }} }}, &.{.{ .paragraph = &.{.{ .text = "two" }} }} } } },
    } },
    .members = &.{
        .{
            .id = "c:a.h#pool.wait",
            .name = "wait",
            .qualified_name = "pool.wait",
            .kind = .field,
            .signature = "bool (*wait)(pool *self)",
            .doc = .{ .blocks = &.{.{ .paragraph = &.{.{ .text = "Waits. Then returns." }} }} },
            .params = &.{.{ .name = "self", .type = .{ .text = "pool *" }, .doc = .{ .blocks = &.{.{ .paragraph = &.{.{ .text = "The pool." }} }} } }},
            .returns = .{ .blocks = &.{.{ .paragraph = &.{.{ .text = "False on failure." }} }} },
        },
        .{ .id = "c:a.h#pool.count", .name = "count", .qualified_name = "pool.count", .kind = .field, .signature = "int count" },
    },
};

test "one symbol is printed in full, with a line for each member" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    try writeSymbol(arena.allocator(), &out.writer, sample, .{ .width = 40 });
    try std.testing.expectEqualStrings(
        \\pool
        \\    struct, public, a.h:3
        \\
        \\    typedef struct pool
        \\
        \\    Runs tasks on a `worker` and never
        \\    on the caller, however long that
        \\    takes.
        \\
        \\    - one
        \\    - two
        \\
        \\    Members:
        \\      wait   field  Waits.
        \\      count  field
        \\
    , out.written());
}

test "a document is printed with its documented symbols only" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    try write(arena.allocator(), &out.writer, "Pool", .{
        .files = &.{.{ .path = "a.h", .language = "c" }},
        .symbols = &.{.{ .id = "c:a.h", .name = "a", .qualified_name = "a.h", .kind = .module, .locations = &.{.{ .file = "a.h", .line = 1 }}, .members = sample.members }},
    }, .{});
    try std.testing.expectEqualStrings(
        \\Pool
        \\====
        \\
        \\pool.wait
        \\    field, public
        \\
        \\    bool (*wait)(pool *self)
        \\
        \\    Waits. Then returns.
        \\
        \\    Parameters:
        \\      self (pool *)
        \\        The pool.
        \\
        \\    Returns:
        \\      False on failure.
        \\
    , out.written());
}
