//! Writes a document as one plain Markdown file.
//!
//! Only the symbols of documented files are written, and of those only the ones with
//! something to say. A symbol gets a section when it carries documentation of any kind or
//! an example, or when one of its members does. With a single file the sections are
//! second-level; with several, each file gets a second-level section named after its path
//! and its symbols move one level down. A member is headed by its qualified name, so a
//! heading is unambiguous when read out of context. A namespace without documentation of its
//! own gets no section: what it holds is written in its place. A file that says nothing
//! itself and holds only namespaces gets no section either: what its namespaces hold is
//! written under one section per namespace, named after it, after the sections of the other
//! files and in the order of the names, so that a namespace spread over many files reads as
//! one. The sentences a file
//! verifies close it as a list under "Verified behaviour".
//!
//! Documentation arrives as an `ir.Text` and is written out as Markdown here: this is the
//! only place of the package that produces that markup. A mention whose target has a
//! section becomes a link to it. The link target is the anchor a Markdown renderer derives
//! from the heading: its text in lower case, without punctuation, with a counter appended
//! when the same text was already used. No anchor is written into the file.
//!
//! `writePages` writes the same document as a directory of smaller files, for a tool that
//! makes a site of them: one for each file or namespace, one for each type with documented
//! members, an index and a table of contents.

const std = @import("std");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const deepest_heading = 6;

/// What writing can fail with: the arena or the writer.
pub const Error = Allocator.Error || Writer.Error;

/// Renders `document` under a first-level heading carrying `title`.
pub fn write(arena: Allocator, writer: *Writer, title: []const u8, document: ir.Document) Error!void {
    var renderer: Renderer = .{ .arena = arena, .roots = try rootsOf(arena, document), .title = title };
    var discarding: Writer.Discarding = .init(&.{});
    renderer.writer = &discarding.writer;
    renderer.collecting = true;
    try renderer.run();

    renderer.writer = writer;
    renderer.collecting = false;
    renderer.used.clearRetainingCapacity();
    try renderer.run();
}

/// One file of a document written as several.
pub const Page = struct {
    /// Name of the file, with no directory in it.
    path: []const u8,
    /// What the file holds.
    text: []const u8,
};

/// Renders `document` as several files meant for one directory: a page per section that
/// `write` would give a file or a namespace, a page per type of it that has documented
/// members, `index.md` listing the first under `title`, and `toc.yml`, which is the same
/// list with the types under each, as a sequence of entries with a name, the file it leads to
/// and the entries under it. A page is
/// named after what it documents, in lower case. A mention links across pages.
pub fn writePages(arena: Allocator, title: []const u8, document: ir.Document) Error![]const Page {
    var renderer: Renderer = .{ .arena = arena, .roots = try rootsOf(arena, document), .title = title };
    var plan: std.ArrayList(Planned) = .empty;
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    for (renderer.roots, 0..) |root, index| {
        try plan.append(arena, .{ .root = index, .symbol = root.symbol });
        try files.append(arena, try fileName(arena, &names, root.symbol.qualified_name));
        var types: std.ArrayList(ir.Symbol) = .empty;
        try typesOf(arena, root.symbol.members, &types);
        for (types.items) |found| {
            try renderer.paged.put(arena, found.id, plan.items.len);
            try plan.append(arena, .{ .root = index, .symbol = found, .is_type = true });
            try files.append(arena, try fileName(arena, &names, found.qualified_name));
        }
    }
    renderer.files = files.items;

    var discarding: Writer.Discarding = .init(&.{});
    renderer.writer = &discarding.writer;
    renderer.collecting = true;
    for (plan.items, 0..) |planned, index| try renderer.page(planned, index, plan.items);

    var pages: std.ArrayList(Page) = .empty;
    renderer.collecting = false;
    for (plan.items, 0..) |planned, index| {
        var out: Writer.Allocating = .init(arena);
        renderer.writer = &out.writer;
        try renderer.page(planned, index, plan.items);
        try pages.append(arena, .{ .path = files.items[index], .text = out.written() });
    }

    var index_page: Writer.Allocating = .init(arena);
    var toc: Writer.Allocating = .init(arena);
    try index_page.writer.print("# {s}\n\n", .{title});
    for (plan.items, 0..) |planned, index| {
        if (planned.is_type) {
            try toc.writer.print("  - name: {s}\n    href: {s}\n", .{ try yamlString(arena, planned.symbol.name), files.items[index] });
            continue;
        }
        try index_page.writer.print("- [{s}]({s})\n", .{ try renderer.code(planned.symbol.qualified_name), files.items[index] });
        try toc.writer.print("- name: {s}\n  href: {s}\n", .{ try yamlString(arena, planned.symbol.qualified_name), files.items[index] });
        if (index + 1 < plan.items.len and plan.items[index + 1].is_type) try toc.writer.writeAll("  items:\n");
    }
    try pages.append(arena, .{ .path = "index.md", .text = index_page.written() });
    try pages.append(arena, .{ .path = "toc.yml", .text = toc.written() });
    return pages.toOwnedSlice(arena);
}

const Planned = struct {
    root: usize,
    symbol: ir.Symbol,
    is_type: bool = false,
};

fn typesOf(arena: Allocator, list: []const ir.Symbol, out: *std.ArrayList(ir.Symbol)) Allocator.Error!void {
    for (list) |symbol| {
        if (symbol.kind == .namespace and symbol.doc.isEmpty()) {
            try typesOf(arena, symbol.members, out);
            continue;
        }
        if (symbol.kind != .type or !symbol.hasDocumentation()) continue;
        const holds = for (symbol.members) |member| {
            if (member.hasDocumentation()) break true;
        } else false;
        if (holds) try out.append(arena, symbol);
    }
}

fn fileName(arena: Allocator, taken: *std.StringHashMapUnmanaged(usize), name: []const u8) Allocator.Error![]const u8 {
    var slug: std.ArrayList(u8) = .empty;
    for (name) |ch| {
        const kept = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_';
        if (kept) {
            try slug.append(arena, std.ascii.toLower(ch));
        } else if (slug.items.len != 0 and slug.items[slug.items.len - 1] != '-') try slug.append(arena, '-');
    }
    if (slug.items.len == 0 or std.mem.eql(u8, slug.items, "index") or std.mem.eql(u8, slug.items, "toc")) try slug.appendSlice(arena, "-page");
    const entry = try taken.getOrPut(arena, try arena.dupe(u8, slug.items));
    if (entry.found_existing) {
        entry.value_ptr.* += 1;
        return std.fmt.allocPrint(arena, "{s}-{d}.md", .{ slug.items, entry.value_ptr.* });
    }
    entry.value_ptr.* = 0;
    return std.fmt.allocPrint(arena, "{s}.md", .{slug.items});
}

fn yamlString(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (name) |ch| {
        if (ch == '"' or ch == '\\') try out.append(arena, '\\');
        try out.append(arena, ch);
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

fn rootsOf(arena: Allocator, document: ir.Document) Allocator.Error![]const Root {
    var roots: std.ArrayList(Root) = .empty;
    var spaces: std.ArrayList(Space) = .empty;
    for (document.symbols) |symbol| {
        const file = fileOf(document, symbol) orelse continue;
        if (!file.documented or !hasContent(symbol)) continue;
        if (isDissolved(symbol)) {
            try gather(arena, &spaces, symbol.members, file.language);
        } else try roots.append(arena, .{ .symbol = symbol, .language = file.language });
    }
    std.mem.sort(Space, spaces.items, {}, Space.before);
    for (spaces.items) |*space| {
        var symbol = space.first;
        symbol.doc = space.doc;
        symbol.members = try space.members.toOwnedSlice(arena);
        try roots.append(arena, .{ .symbol = symbol, .language = space.language, .aliases = try space.ids.toOwnedSlice(arena) });
    }
    return roots.toOwnedSlice(arena);
}

const Anchor = struct {
    page: usize,
    name: []const u8,
};

const Root = struct {
    symbol: ir.Symbol,
    language: []const u8,
    aliases: []const []const u8 = &.{},
};

const Space = struct {
    first: ir.Symbol,
    language: []const u8,
    doc: ir.Text = .{},
    members: std.ArrayList(ir.Symbol) = .empty,
    ids: std.ArrayList([]const u8) = .empty,

    fn before(_: void, a: Space, b: Space) bool {
        return std.mem.lessThan(u8, a.first.qualified_name, b.first.qualified_name);
    }
};

fn isDissolved(root: ir.Symbol) bool {
    if (!root.doc.isEmpty() or root.verified.len != 0) return false;
    for (root.members) |member| {
        if (member.kind != .namespace and member.hasDocumentation()) return false;
    }
    return true;
}

fn gather(arena: Allocator, spaces: *std.ArrayList(Space), list: []const ir.Symbol, language: []const u8) Allocator.Error!void {
    for (list) |symbol| {
        if (symbol.kind != .namespace or !symbol.hasDocumentation()) continue;
        var direct = false;
        for (symbol.members) |member| {
            if (member.kind != .namespace and member.hasDocumentation()) direct = true;
        }
        if (direct or !symbol.doc.isEmpty()) {
            const space = for (spaces.items) |*known| {
                if (std.mem.eql(u8, known.first.qualified_name, symbol.qualified_name) and std.mem.eql(u8, known.language, language)) break known;
            } else added: {
                try spaces.append(arena, .{ .first = symbol, .language = language });
                break :added &spaces.items[spaces.items.len - 1];
            };
            try space.ids.append(arena, symbol.id);
            if (space.doc.isEmpty()) space.doc = symbol.doc;
            for (symbol.members) |member| {
                if (member.kind != .namespace) try space.members.append(arena, member);
            }
        }
        try gather(arena, spaces, symbol.members, language);
    }
}

fn fileOf(document: ir.Document, symbol: ir.Symbol) ?ir.File {
    if (symbol.locations.len == 0) return null;
    for (document.files) |file| {
        if (std.mem.eql(u8, file.path, symbol.locations[0].file)) return file;
    }
    return null;
}

fn hasContent(root: ir.Symbol) bool {
    if (!root.doc.isEmpty() or root.verified.len != 0) return true;
    for (root.members) |member| {
        if (member.hasDocumentation()) return true;
    }
    return false;
}

const Renderer = struct {
    arena: Allocator,
    roots: []const Root,
    title: []const u8,
    writer: *Writer = undefined,
    collecting: bool = false,
    used: std.StringHashMapUnmanaged(usize) = .empty,
    anchors: std.StringHashMapUnmanaged(Anchor) = .empty,
    files: []const []const u8 = &.{},
    paged: std.StringHashMapUnmanaged(usize) = .empty,
    current: usize = 0,

    fn page(self: *Renderer, planned: Planned, index: usize, plan: []const Planned) Error!void {
        const writer = self.writer;
        const root = self.roots[planned.root];
        self.current = index;
        self.used.clearRetainingCapacity();
        if (planned.is_type) return self.section(root.language, planned.symbol, 1);
        try self.heading(1, root.symbol.qualified_name, true, root.symbol.id);
        if (self.collecting) {
            const anchor = self.anchors.get(root.symbol.id).?;
            for (root.aliases) |alias| try self.anchors.put(self.arena, alias, anchor);
        }
        if (!root.symbol.doc.isEmpty()) try writer.print("\n{s}\n", .{try self.text(root.symbol.doc)});
        var listed = false;
        for (plan[index + 1 ..], index + 1..) |next, position| {
            if (!next.is_type or next.root != planned.root) break;
            if (!listed) try self.heading(2, "Types", false, null);
            if (!listed) try writer.writeByte('\n');
            listed = true;
            try writer.print("- [{s}]({s})\n", .{ try self.code(next.symbol.name), self.files[position] });
        }
        for (root.symbol.members) |member| try self.section(root.language, member, 2);
        if (root.symbol.verified.len != 0) {
            try self.heading(2, "Verified behaviour", false, null);
            try writer.writeByte('\n');
            for (root.symbol.verified) |sentence| try writer.print("- {s}\n", .{sentence});
        }
    }

    fn linkTo(self: *Renderer, target: []const u8) Allocator.Error!?[]const u8 {
        const anchor = self.anchors.get(target) orelse return null;
        if (anchor.page == self.current) return try std.fmt.allocPrint(self.arena, "#{s}", .{anchor.name});
        return try std.fmt.allocPrint(self.arena, "{s}#{s}", .{ self.files[anchor.page], anchor.name });
    }

    fn run(self: *Renderer) Error!void {
        const writer = self.writer;
        try self.heading(1, self.title, false, null);
        const grouped = self.roots.len > 1;
        const level: usize = if (grouped) 3 else 2;
        for (self.roots) |root| {
            if (grouped) {
                try self.heading(2, root.symbol.qualified_name, true, root.symbol.id);
                if (self.collecting) {
                    const anchor = self.anchors.get(root.symbol.id).?;
                    for (root.aliases) |alias| try self.anchors.put(self.arena, alias, anchor);
                }
            }
            if (!root.symbol.doc.isEmpty()) try writer.print("\n{s}\n", .{try self.text(root.symbol.doc)});
            for (root.symbol.members) |member| try self.section(root.language, member, level);
            if (root.symbol.verified.len != 0) {
                try self.heading(level, "Verified behaviour", false, null);
                try writer.writeByte('\n');
                for (root.symbol.verified) |sentence| try writer.print("- {s}\n", .{sentence});
            }
        }
    }

    fn section(self: *Renderer, language: []const u8, symbol: ir.Symbol, level: usize) Error!void {
        if (!symbol.hasDocumentation()) return;
        if (self.paged.get(symbol.id)) |own| {
            if (own != self.current) return;
        }
        const writer = self.writer;
        if (symbol.kind == .namespace and symbol.doc.isEmpty()) {
            for (symbol.members) |member| try self.section(language, member, level);
            return;
        }
        try self.heading(level, symbol.qualified_name, true, symbol.id);
        try writer.print("\n```{s}\n{s}\n```\n", .{ language, symbol.signature });
        if (symbol.kind == .alias) {
            if (try self.linkTo(symbol.target)) |anchor| {
                try writer.print("\nAlias of [{s}]({s}).\n", .{ try self.code(self.nameOf(symbol.target)), anchor });
            }
        }
        if (!symbol.doc.isEmpty()) try writer.print("\n{s}\n", .{try self.text(symbol.doc)});

        var type_table_open = false;
        for (symbol.type_params) |param| {
            if (param.doc.isEmpty()) continue;
            if (!type_table_open) try writer.writeAll("\n| Type parameter | Constraint | Description |\n|---|---|---|\n");
            type_table_open = true;
            try writer.print("| {s} | {s} | {s} |\n", .{ try self.code(param.name), try self.cellCode(param.constraint), try self.cell(param.doc) });
        }
        var table_open = false;
        for (symbol.params) |param| {
            if (param.doc.isEmpty()) continue;
            if (!table_open) try writer.writeAll("\n| Parameter | Type | Description |\n|---|---|---|\n");
            table_open = true;
            try writer.print("| {s} | {s} | {s} |\n", .{ try self.code(param.name), try self.typeCell(param.type), try self.cell(param.doc) });
        }
        if (!symbol.returns.isEmpty()) try writer.print("\n**Returns:** {s}\n", .{try self.text(symbol.returns)});
        var raises_open = false;
        for (symbol.raises) |raised| {
            if (raised.doc.isEmpty()) continue;
            if (!raises_open) try writer.writeAll("\n| Raises | When |\n|---|---|\n");
            raises_open = true;
            try writer.print("| {s} | {s} |\n", .{ try self.typeCell(raised.type), try self.cell(raised.doc) });
        }
        for (symbol.examples) |example| {
            try writer.print("\n**Example:**\n\n```{s}\n{s}\n```\n", .{ if (example.language.len != 0) example.language else language, example.code });
        }
        for (symbol.members) |member| try self.section(language, member, level + 1);
    }

    fn nameOf(self: *Renderer, id: []const u8) []const u8 {
        for (self.roots) |root| {
            if (find(root.symbol, id)) |symbol| return symbol.qualified_name;
        }
        return id;
    }

    fn heading(self: *Renderer, level: usize, label: []const u8, as_code: bool, id: ?[]const u8) Error!void {
        const writer = self.writer;
        if (level != 1) try writer.writeByte('\n');
        try writer.splatByteAll('#', @min(level, deepest_heading));
        if (as_code) try writer.print(" `{s}`\n", .{label}) else try writer.print(" {s}\n", .{label});

        var slug: std.ArrayList(u8) = .empty;
        for (label) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                try slug.append(self.arena, std.ascii.toLower(ch));
            } else if (ch == ' ') {
                try slug.append(self.arena, '-');
            }
        }
        const entry = try self.used.getOrPut(self.arena, slug.items);
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 0;
        }
        if (!self.collecting) return;
        const target = id orelse return;
        const anchor = if (entry.value_ptr.* == 0) slug.items else try std.fmt.allocPrint(self.arena, "{s}-{d}", .{ slug.items, entry.value_ptr.* });
        try self.anchors.put(self.arena, target, .{ .page = self.current, .name = anchor });
    }

    fn text(self: *Renderer, source: ir.Text) Error![]const u8 {
        return self.blocks(source.blocks);
    }

    fn cell(self: *Renderer, source: ir.Text) Error![]const u8 {
        return flat(self.arena, try self.text(source));
    }

    fn cellCode(self: *Renderer, content: []const u8) Error![]const u8 {
        if (content.len == 0) return "";
        return flat(self.arena, try self.code(content));
    }

    fn typeCell(self: *Renderer, written: ir.TypeRef) Error![]const u8 {
        const shown = try self.cellCode(written.text);
        const anchor = try self.linkTo(written.target) orelse return shown;
        if (shown.len == 0) return shown;
        return std.fmt.allocPrint(self.arena, "[{s}]({s})", .{ shown, anchor });
    }

    fn blocks(self: *Renderer, list: []const ir.Block) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (list, 0..) |block, index| {
            if (index != 0) try out.appendSlice(self.arena, "\n\n");
            switch (block) {
                .paragraph => |content| try out.appendSlice(self.arena, try self.inlines(content)),
                .heading => |title| try out.print(self.arena, "**{s}**", .{try self.inlines(title.content)}),
                .code => |source| try out.print(self.arena, "```{s}\n{s}\n```", .{ source.language, source.text }),
                .list => |listed| for (listed.items, 0..) |item, at| {
                    if (at != 0) try out.append(self.arena, '\n');
                    const marker = if (listed.start) |start| try std.fmt.allocPrint(self.arena, "{d}. ", .{start + at}) else "- ";
                    try self.indented(&out, marker, try self.blocks(item));
                },
                .quote => |quoted| {
                    var lines = std.mem.splitScalar(u8, try self.blocks(quoted), '\n');
                    var first = true;
                    while (lines.next()) |line| {
                        if (!first) try out.append(self.arena, '\n');
                        first = false;
                        try out.appendSlice(self.arena, if (line.len == 0) ">" else "> ");
                        try out.appendSlice(self.arena, line);
                    }
                },
                .note => |note| {
                    try out.appendSlice(self.arena, "**");
                    if (note.label.len != 0) try out.append(self.arena, std.ascii.toUpper(note.label[0]));
                    if (note.label.len > 1) try out.appendSlice(self.arena, note.label[1..]);
                    try out.appendSlice(self.arena, ":** ");
                    try out.appendSlice(self.arena, try self.blocks(note.blocks));
                },
                .table => |table| {
                    const columns = if (table.header.len != 0) table.header.len else if (table.rows.len != 0) table.rows[0].len else 0;
                    try out.append(self.arena, '|');
                    for (0..columns) |column| {
                        const content = if (column < table.header.len) try flat(self.arena, try self.inlines(table.header[column])) else "";
                        try out.print(self.arena, " {s} |", .{content});
                    }
                    try out.appendSlice(self.arena, "\n|");
                    for (0..columns) |_| try out.appendSlice(self.arena, "---|");
                    for (table.rows) |row| {
                        try out.appendSlice(self.arena, "\n|");
                        for (row) |content| try out.print(self.arena, " {s} |", .{try flat(self.arena, try self.inlines(content))});
                    }
                },
                .rule => try out.appendSlice(self.arena, "---"),
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    fn indented(self: *Renderer, out: *std.ArrayList(u8), marker: []const u8, content: []const u8) Error!void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (first) {
                try out.appendSlice(self.arena, marker);
            } else {
                try out.append(self.arena, '\n');
                if (line.len != 0) try out.appendNTimes(self.arena, ' ', marker.len);
            }
            first = false;
            try out.appendSlice(self.arena, line);
        }
    }

    fn inlines(self: *Renderer, list: []const ir.Inline) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (list) |piece| switch (piece) {
            .text => |characters| for (characters) |ch| {
                if (std.mem.indexOfScalar(u8, "\\`*[]<", ch) != null) try out.append(self.arena, '\\');
                try out.append(self.arena, ch);
            },
            .code, .param => |characters| try out.appendSlice(self.arena, try self.code(characters)),
            .ref => |ref| if (try self.linkTo(ref.target)) |anchor| {
                try out.print(self.arena, "[{s}]({s})", .{ try self.code(ref.text), anchor });
            } else {
                try out.appendSlice(self.arena, try self.code(ref.text));
            },
            .emphasis => |content| try out.print(self.arena, "*{s}*", .{try self.inlines(content)}),
            .strong => |content| try out.print(self.arena, "**{s}**", .{try self.inlines(content)}),
            .link => |link| try out.print(self.arena, "[{s}]({s})", .{ try self.inlines(link.content), link.url }),
            .image => |image| try out.print(self.arena, "![{s}]({s})", .{ try self.inlines(image.content), image.url }),
            .line_break => try out.appendSlice(self.arena, "\\\n"),
        };
        return out.toOwnedSlice(self.arena);
    }

    fn code(self: *Renderer, content: []const u8) Error![]const u8 {
        var longest: usize = 0;
        var run_length: usize = 0;
        for (content) |ch| {
            run_length = if (ch == '`') run_length + 1 else 0;
            longest = @max(longest, run_length);
        }
        if (longest == 0) return std.fmt.allocPrint(self.arena, "`{s}`", .{content});
        var out: std.ArrayList(u8) = .empty;
        try out.appendNTimes(self.arena, '`', longest + 1);
        try out.print(self.arena, " {s} ", .{content});
        try out.appendNTimes(self.arena, '`', longest + 1);
        return out.toOwnedSlice(self.arena);
    }
};

fn find(symbol: ir.Symbol, id: []const u8) ?ir.Symbol {
    if (std.mem.eql(u8, symbol.id, id)) return symbol;
    for (symbol.members) |member| {
        if (find(member, id)) |found| return found;
    }
    return null;
}

fn flat(arena: Allocator, content: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (content) |ch| switch (ch) {
        '\n' => if (out.items.len == 0 or out.items[out.items.len - 1] != ' ') try out.append(arena, ' '),
        '|' => try out.appendSlice(arena, "\\|"),
        else => try out.append(arena, ch),
    };
    return out.toOwnedSlice(arena);
}

fn words(comptime content: []const u8) ir.Text {
    return .{ .blocks = &.{.{ .paragraph = &.{.{ .text = content }} }} };
}

fn module(comptime path: []const u8, comptime language: []const u8, doc: ir.Text, members: []const ir.Symbol, verified: []const []const u8) ir.Symbol {
    return .{
        .id = language ++ ":" ++ path,
        .name = path,
        .qualified_name = path,
        .kind = .module,
        .locations = &.{.{ .file = path }},
        .doc = doc,
        .verified = verified,
        .members = members,
    };
}

fn render(arena: Allocator, document: ir.Document) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try write(arena, &out.writer, "Title", document);
    return out.written();
}

test "a single file is written flat, with an example and its verified sentences as a closing list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output = try render(arena.allocator(), .{
        .files = &.{.{ .path = "a.zig", .language = "zig" }},
        .symbols = &.{module("a.zig", "zig", words("How it works."), &.{
            .{ .id = "zig:a.zig#run", .name = "run", .qualified_name = "run", .kind = .function, .signature = "fn run() void", .doc = words("Runs."), .examples = &.{.{ .language = "zig", .code = "run();" }} },
            .{ .id = "zig:a.zig#hidden", .name = "hidden", .qualified_name = "hidden", .kind = .function, .signature = "fn hidden() void" },
        }, &.{ "it runs", "it stops" })},
    });
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\How it works.
        \\
        \\## `run`
        \\
        \\```zig
        \\fn run() void
        \\```
        \\
        \\Runs.
        \\
        \\**Example:**
        \\
        \\```zig
        \\run();
        \\```
        \\
        \\## Verified behaviour
        \\
        \\- it runs
        \\- it stops
        \\
    , output);
}

test "a member is headed by its qualified name, only documented parameters are listed and a type links to its section" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output = try render(arena.allocator(), .{
        .files = &.{.{ .path = "a.h", .language = "c" }},
        .symbols = &.{module("a.h", "c", .{}, &.{.{
            .id = "c:a.h#pool",
            .name = "pool",
            .qualified_name = "pool",
            .kind = .type,
            .signature = "typedef struct pool",
            .members = &.{.{
                .id = "c:a.h#pool.wait",
                .name = "wait",
                .qualified_name = "pool.wait",
                .kind = .field,
                .signature = "bool (*wait)(pool *self, int code)",
                .params = &.{
                    .{ .name = "self", .type = .{ .text = "pool *", .target = "c:a.h#pool" }, .doc = words("The pool | borrowed,\nnever NULL.") },
                    .{ .name = "code", .type = .{ .text = "int" } },
                },
                .returns = words("False on failure."),
            }},
        }}, &.{})},
    });
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\## `pool`
        \\
        \\```c
        \\typedef struct pool
        \\```
        \\
        \\### `pool.wait`
        \\
        \\```c
        \\bool (*wait)(pool *self, int code)
        \\```
        \\
        \\| Parameter | Type | Description |
        \\|---|---|---|
        \\| `self` | [`pool *`](#pool) | The pool \| borrowed, never NULL. |
        \\
        \\**Returns:** False on failure.
        \\
    , output);
}

test "a mention links to the section of its target, across files and with repeated headings numbered" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output = try render(arena.allocator(), .{
        .files = &.{
            .{ .path = "pool.h", .language = "c" },
            .{ .path = "hidden.zig", .language = "zig", .documented = false },
            .{ .path = "pool.zig", .language = "zig" },
        },
        .symbols = &.{
            module("pool.h", "c", .{}, &.{.{ .id = "c:pool.h#wait", .name = "wait", .qualified_name = "wait", .kind = .function, .signature = "bool wait(void)", .doc = words("Waits.") }}, &.{}),
            module("hidden.zig", "zig", .{}, &.{.{ .id = "zig:hidden.zig#secret", .name = "secret", .qualified_name = "secret", .kind = .function, .signature = "fn secret() void", .doc = words("Hidden.") }}, &.{}),
            module("pool.zig", "zig", .{ .blocks = &.{.{ .paragraph = &.{
                .{ .text = "Implements " },
                .{ .ref = .{ .text = "wait", .target = "c:pool.h#wait" } },
                .{ .text = " with " },
                .{ .ref = .{ .text = "Pool.wait", .target = "zig:pool.zig#wait" } },
                .{ .text = ", never " },
                .{ .ref = .{ .text = "secret", .target = "zig:hidden.zig#secret" } },
                .{ .text = ", in " },
                .{ .ref = .{ .text = "pool.h", .target = "c:pool.h" } },
                .{ .text = "." },
            } }} }, &.{.{ .id = "zig:pool.zig#wait", .name = "wait", .qualified_name = "wait", .kind = .function, .signature = "fn wait() bool", .doc = words("Waits too.") }}, &.{}),
        },
    });
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\## `pool.h`
        \\
        \\### `wait`
        \\
        \\```c
        \\bool wait(void)
        \\```
        \\
        \\Waits.
        \\
        \\## `pool.zig`
        \\
        \\Implements [`wait`](#wait) with [`Pool.wait`](#wait-1), never `secret`, in [`pool.h`](#poolh).
        \\
        \\### `wait`
        \\
        \\```zig
        \\fn wait() bool
        \\```
        \\
        \\Waits too.
        \\
    , output);
}

test "every kind of block and inline is written as the markup that reads back the same" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output = try render(arena.allocator(), .{
        .files = &.{.{ .path = "a.zig", .language = "zig" }},
        .symbols = &.{module("a.zig", "zig", .{ .blocks = &.{
            .{ .paragraph = &.{ .{ .text = "A *star*, " }, .{ .emphasis = &.{.{ .text = "stressed" }} }, .{ .text = ", " }, .{ .strong = &.{.{ .text = "strong" }} }, .{ .text = ", " }, .{ .code = "a ` b" }, .{ .text = ", " }, .{ .param = "count" }, .{ .text = " and " }, .{ .link = .{ .url = "https://example.org", .content = &.{.{ .text = "a site" }} } }, .{ .text = "." } } },
            .{ .heading = .{ .level = 2, .content = &.{.{ .text = "Inside" }} } },
            .{ .code = .{ .language = "zig", .text = "const a = 1;" } },
            .{ .list = .{ .items = &.{
                &.{.{ .paragraph = &.{.{ .text = "one" }} }},
                &.{ .{ .paragraph = &.{.{ .text = "two" }} }, .{ .list = .{ .start = 3, .items = &.{&.{.{ .paragraph = &.{.{ .text = "inner\nline" }} }}} } } },
            } } },
            .{ .quote = &.{.{ .paragraph = &.{.{ .text = "quoted\ntwice" }} }} },
            .{ .note = .{ .label = "warning", .blocks = &.{.{ .paragraph = &.{.{ .text = "Careful." }} }} } },
            .{ .table = .{ .header = &.{ &.{.{ .text = "name" }}, &.{.{ .text = "use" }} }, .rows = &.{&.{ &.{.{ .code = "wait" }}, &.{.{ .text = "a|b" }} }} } },
            .rule,
        } }, &.{}, &.{})},
    });
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\A \*star\*, *stressed*, **strong**, `` a ` b ``, `count` and [a site](https://example.org).
        \\
        \\**Inside**
        \\
        \\```zig
        \\const a = 1;
        \\```
        \\
        \\- one
        \\- two
        \\
        \\  3. inner
        \\     line
        \\
        \\> quoted
        \\> twice
        \\
        \\**Warning:** Careful.
        \\
        \\| name | use |
        \\|---|---|
        \\| `wait` | a\|b |
        \\
        \\---
        \\
    , output);
}

test "files that hold only namespaces are written as one section per namespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output = try render(arena.allocator(), .{
        .files = &.{ .{ .path = "B.cs", .language = "csharp" }, .{ .path = "A.cs", .language = "csharp" } },
        .symbols = &.{
            module("B.cs", "csharp", .{}, &.{.{
                .id = "csharp:B.cs#Ke",
                .name = "Ke",
                .qualified_name = "Ke",
                .kind = .namespace,
                .members = &.{.{ .id = "csharp:B.cs#Ke.Worker", .name = "Worker", .qualified_name = "Ke.Worker", .kind = .type, .signature = "class Worker", .doc = .{ .blocks = &.{.{ .paragraph = &.{ .{ .text = "Works for a " }, .{ .ref = .{ .text = "Pool", .target = "csharp:A.cs#Ke.Pool" } }, .{ .text = "." } } }} } }},
            }}, &.{}),
            module("A.cs", "csharp", .{}, &.{.{
                .id = "csharp:A.cs#Ke",
                .name = "Ke",
                .qualified_name = "Ke",
                .kind = .namespace,
                .members = &.{.{ .id = "csharp:A.cs#Ke.Pool", .name = "Pool", .qualified_name = "Ke.Pool", .kind = .type, .signature = "class Pool", .doc = words("Runs.") }},
            }}, &.{}),
        },
    });
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\## `Ke.Worker`
        \\
        \\```csharp
        \\class Worker
        \\```
        \\
        \\Works for a [`Pool`](#kepool).
        \\
        \\## `Ke.Pool`
        \\
        \\```csharp
        \\class Pool
        \\```
        \\
        \\Runs.
        \\
    , output);
}

test "a document written as pages has a page per section and per type, an index and a table of contents" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pages = try writePages(arena.allocator(), "Title", .{
        .files = &.{.{ .path = "A.cs", .language = "csharp" }},
        .symbols = &.{module("A.cs", "csharp", .{}, &.{.{
            .id = "csharp:A.cs#Ke",
            .name = "Ke",
            .qualified_name = "Ke",
            .kind = .namespace,
            .members = &.{
                .{
                    .id = "csharp:A.cs#Ke.Pool",
                    .name = "Pool",
                    .qualified_name = "Ke.Pool",
                    .kind = .type,
                    .signature = "class Pool",
                    .doc = words("Runs."),
                    .members = &.{.{ .id = "csharp:A.cs#Ke.Pool.Stop()", .name = "Stop", .qualified_name = "Ke.Pool.Stop", .kind = .function, .signature = "void Stop()", .doc = words("Stops.") }},
                },
                .{
                    .id = "csharp:A.cs#Ke.Mode",
                    .name = "Mode",
                    .qualified_name = "Ke.Mode",
                    .kind = .type,
                    .signature = "enum Mode",
                    .doc = .{ .blocks = &.{.{ .paragraph = &.{ .{ .text = "How a " }, .{ .ref = .{ .text = "Pool.Stop", .target = "csharp:A.cs#Ke.Pool.Stop()" } }, .{ .text = " ends." } } }} },
                },
            },
        }}, &.{})},
    });
    try std.testing.expectEqual(4, pages.len);
    try std.testing.expectEqualStrings("ke.md", pages[0].path);
    try std.testing.expectEqualStrings(
        \\# `Ke`
        \\
        \\## Types
        \\
        \\- [`Pool`](ke.pool.md)
        \\
        \\## `Ke.Mode`
        \\
        \\```csharp
        \\enum Mode
        \\```
        \\
        \\How a [`Pool.Stop`](ke.pool.md#kepoolstop) ends.
        \\
    , pages[0].text);
    try std.testing.expectEqualStrings("ke.pool.md", pages[1].path);
    try std.testing.expect(std.mem.startsWith(u8, pages[1].text, "# `Ke.Pool`\n"));
    try std.testing.expect(std.mem.indexOf(u8, pages[1].text, "## `Ke.Pool.Stop`") != null);
    try std.testing.expectEqualStrings("# Title\n\n- [`Ke`](ke.md)\n", pages[2].text);
    try std.testing.expectEqualStrings("- name: \"Ke\"\n  href: ke.md\n  items:\n  - name: \"Pool\"\n    href: ke.pool.md\n", pages[3].text);
}
