//! Reads the XML a C# documentation comment is written in into the document model.
//!
//! What is read is the text of the comment with its `///` already taken off each line. The
//! elements that stand at the top say what each part is about: `<summary>`, `<remarks>` and
//! `<value>` are the documentation itself, in the order they are written, `<param>` and
//! `<typeparam>` document the parameter their `name=` gives, `<returns>` what is returned,
//! `<exception>` a failure whose type its `cref=` gives, and each `<code>` inside an
//! `<example>` is an example, the words around it joining the documentation. Text that
//! stands in no element is documentation too, so a comment without any element is read
//! whole. `<inheritdoc>` asks for the documentation of another symbol, the one its `cref=`
//! names when it has one.
//!
//! Inside a part, `<para>` is a paragraph, and so is text set apart by an empty line.
//! `<code>` is a block of code kept as written, `<list>` a list with one item per `<item>`,
//! numbered when its `type=` is "number", and a `<term>` is joined to its `<description>` by
//! a colon. In a line, `<see>` and `<seealso>` with a `cref=` mention a symbol, with a
//! `langword=` are code and with an `href=` are a link, `<paramref>` mentions a parameter,
//! `<typeparamref>` and `<c>` are code, `<b>` and `<strong>` stress more than `<i>` and
//! `<em>`, and `<br>` ends a line. An element not listed here is read for what it holds.
//!
//! The name in a `cref=` loses what the compiler does not need to find it by name: the
//! letter and colon in front, the list of parameters, and the type arguments in braces.
//!
//! Markup that is not well formed does not fail. A `<` that opens nothing is a character,
//! and an element left open ends where its parent does.

const std = @import("std");
const ir = @import("ir.zig");
const markdown_text = @import("markdown_text.zig");

const Allocator = std.mem.Allocator;

/// What a comment says about something it names.
pub const Named = struct {
    /// The name of the parameter, or the type of the failure.
    name: []const u8,
    /// What is said.
    text: ir.Text,
};

/// What one comment says.
pub const Comment = struct {
    /// The documentation.
    blocks: []const ir.Block = &.{},
    /// What is said of each parameter, in the order written.
    params: []const Named = &.{},
    /// What is said of each parameter that stands for a type.
    type_params: []const Named = &.{},
    /// What is said to be returned.
    returns: ir.Text = .{},
    /// The failures said to be raised, each under the name of its type.
    raises: []const Named = &.{},
    /// The code given as examples.
    examples: []const ir.Example = &.{},
    /// The name of the symbol whose documentation is asked for, empty when none is named,
    /// and null when the comment asks for none.
    inherits: ?[]const u8 = null,
};

/// Reads `raw`, the lines of a comment joined by `\n` without their `///`.
pub fn parse(arena: Allocator, raw: []const u8) Allocator.Error!Comment {
    var scanner: Scanner = .{ .arena = arena, .source = raw };
    const top = try scanner.children(null);
    var reader: Reader = .{ .arena = arena };
    var loose: std.ArrayList(Piece) = .empty;
    for (top) |piece| {
        const element = switch (piece) {
            .text => {
                try loose.append(arena, piece);
                continue;
            },
            .element => |element| element,
        };
        if (is(element.name, "summary") or is(element.name, "remarks") or is(element.name, "value")) {
            try reader.flush(&loose);
            try reader.blocks.appendSlice(arena, try reader.blocksOf(element.children));
        } else if (is(element.name, "param")) {
            try reader.params.append(arena, .{ .name = element.attribute("name"), .text = .{ .blocks = try reader.blocksOf(element.children) } });
        } else if (is(element.name, "typeparam")) {
            try reader.type_params.append(arena, .{ .name = element.attribute("name"), .text = .{ .blocks = try reader.blocksOf(element.children) } });
        } else if (is(element.name, "returns")) {
            reader.returns = .{ .blocks = try reader.blocksOf(element.children) };
        } else if (is(element.name, "exception")) {
            try reader.raises.append(arena, .{ .name = try nameOf(arena, element.attribute("cref")), .text = .{ .blocks = try reader.blocksOf(element.children) } });
        } else if (is(element.name, "example")) {
            try reader.flush(&loose);
            var prose: std.ArrayList(Piece) = .empty;
            for (element.children) |child| {
                if (child == .element and is(child.element.name, "code")) {
                    try reader.examples.append(arena, .{ .language = "csharp", .code = try verbatim(arena, child.element.children) });
                } else try prose.append(arena, child);
            }
            try reader.blocks.appendSlice(arena, try reader.blocksOf(prose.items));
        } else if (is(element.name, "inheritdoc")) {
            reader.inherits = try nameOf(arena, element.attribute("cref"));
        } else if (is(element.name, "include")) {
            continue;
        } else {
            try loose.append(arena, piece);
        }
    }
    try reader.flush(&loose);
    return .{
        .blocks = try reader.blocks.toOwnedSlice(arena),
        .params = try reader.params.toOwnedSlice(arena),
        .type_params = try reader.type_params.toOwnedSlice(arena),
        .returns = reader.returns,
        .raises = try reader.raises.toOwnedSlice(arena),
        .examples = try reader.examples.toOwnedSlice(arena),
        .inherits = reader.inherits,
    };
}

/// The name a `cref=` gives, without the prefix, the parameters and the type arguments the
/// compiler writes around it.
pub fn nameOf(arena: Allocator, cref: []const u8) Allocator.Error![]const u8 {
    var name = std.mem.trim(u8, cref, " \t");
    if (name.len > 2 and name[1] == ':' and std.ascii.isAlphabetic(name[0])) name = name[2..];
    if (std.mem.indexOfScalar(u8, name, '(')) |open| name = name[0..open];
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (name) |ch| switch (ch) {
        '{', '<' => depth += 1,
        '}', '>' => depth -|= 1,
        else => if (depth == 0) try out.append(arena, ch),
    };
    return out.toOwnedSlice(arena);
}

const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

const Element = struct {
    name: []const u8,
    attributes: []const Attribute,
    children: []const Piece,

    fn attribute(self: Element, name: []const u8) []const u8 {
        for (self.attributes) |entry| {
            if (is(entry.name, name)) return entry.value;
        }
        return "";
    }

    fn has(self: Element, name: []const u8) bool {
        for (self.attributes) |entry| {
            if (is(entry.name, name)) return true;
        }
        return false;
    }
};

const Piece = union(enum) {
    text: []const u8,
    element: Element,
};

fn is(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == ':' or ch == '.';
}

const entities = [_]struct { []const u8, u8 }{
    .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&amp;", '&' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' },
};

fn decoded(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, source, '&') == null) return source;
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    next: while (at < source.len) {
        for (entities) |entity| {
            if (std.mem.startsWith(u8, source[at..], entity[0])) {
                try out.append(arena, entity[1]);
                at += entity[0].len;
                continue :next;
            }
        }
        try out.append(arena, source[at]);
        at += 1;
    }
    return out.toOwnedSlice(arena);
}

const Scanner = struct {
    arena: Allocator,
    source: []const u8,
    at: usize = 0,

    fn children(self: *Scanner, parent: ?[]const u8) Allocator.Error![]const Piece {
        var out: std.ArrayList(Piece) = .empty;
        var text_start = self.at;
        while (self.at < self.source.len) {
            if (self.source[self.at] != '<') {
                self.at += 1;
                continue;
            }
            const rest = self.source[self.at..];
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                try self.textUntil(&out, text_start);
                const close = std.mem.indexOf(u8, rest, "]]>") orelse rest.len;
                try out.append(self.arena, .{ .text = rest[@min(9, close)..close] });
                self.at += @min(rest.len, close + 3);
                text_start = self.at;
                continue;
            }
            if (rest.len > 1 and rest[1] == '/') {
                const close = std.mem.indexOfScalar(u8, rest, '>') orelse rest.len;
                const name = std.mem.trim(u8, rest[2..close], " \t\n");
                try self.textUntil(&out, text_start);
                if (parent != null and !is(parent.?, name)) return out.toOwnedSlice(self.arena);
                self.at += @min(rest.len, close + 1);
                if (parent != null) return out.toOwnedSlice(self.arena);
                text_start = self.at;
                continue;
            }
            if (rest.len < 2 or !std.ascii.isAlphabetic(rest[1])) {
                self.at += 1;
                continue;
            }
            try self.textUntil(&out, text_start);
            try out.append(self.arena, .{ .element = try self.element() });
            text_start = self.at;
        }
        try self.textUntil(&out, text_start);
        return out.toOwnedSlice(self.arena);
    }

    fn textUntil(self: *Scanner, out: *std.ArrayList(Piece), start: usize) Allocator.Error!void {
        if (self.at > start) try out.append(self.arena, .{ .text = try decoded(self.arena, self.source[start..self.at]) });
    }

    fn element(self: *Scanner) Allocator.Error!Element {
        self.at += 1;
        const name_start = self.at;
        while (self.at < self.source.len and isNameChar(self.source[self.at])) self.at += 1;
        const name = self.source[name_start..self.at];
        var attributes: std.ArrayList(Attribute) = .empty;
        while (self.at < self.source.len) {
            const ch = self.source[self.at];
            if (ch == '>') {
                self.at += 1;
                return .{ .name = name, .attributes = try attributes.toOwnedSlice(self.arena), .children = try self.children(name) };
            }
            if (ch == '/') {
                self.at += 1;
                if (self.at < self.source.len and self.source[self.at] == '>') self.at += 1;
                break;
            }
            if (!isNameChar(ch)) {
                self.at += 1;
                continue;
            }
            const key_start = self.at;
            while (self.at < self.source.len and isNameChar(self.source[self.at])) self.at += 1;
            const key = self.source[key_start..self.at];
            while (self.at < self.source.len and std.ascii.isWhitespace(self.source[self.at])) self.at += 1;
            if (self.at >= self.source.len or self.source[self.at] != '=') continue;
            self.at += 1;
            while (self.at < self.source.len and std.ascii.isWhitespace(self.source[self.at])) self.at += 1;
            if (self.at >= self.source.len) break;
            const quote = self.source[self.at];
            if (quote != '"' and quote != '\'') continue;
            const value_start = self.at + 1;
            const value_end = std.mem.indexOfScalarPos(u8, self.source, value_start, quote) orelse self.source.len;
            try attributes.append(self.arena, .{ .name = key, .value = try decoded(self.arena, self.source[value_start..value_end]) });
            self.at = @min(self.source.len, value_end + 1);
        }
        return .{ .name = name, .attributes = try attributes.toOwnedSlice(self.arena), .children = &.{} };
    }
};

fn verbatim(arena: Allocator, pieces: []const Piece) Allocator.Error![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    for (pieces) |piece| switch (piece) {
        .text => |characters| try joined.appendSlice(arena, characters),
        .element => |element| try joined.appendSlice(arena, try verbatim(arena, element.children)),
    };
    var lines: std.ArrayList([]const u8) = .empty;
    var each = std.mem.splitScalar(u8, joined.items, '\n');
    while (each.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, " \t\r"));
    var first: usize = 0;
    var last = lines.items.len;
    while (first < last and lines.items[first].len == 0) first += 1;
    while (last > first and lines.items[last - 1].len == 0) last -= 1;
    var indent: usize = std.math.maxInt(usize);
    for (lines.items[first..last]) |line| {
        if (line.len == 0) continue;
        indent = @min(indent, line.len - std.mem.trimStart(u8, line, " \t").len);
    }
    var out: std.ArrayList(u8) = .empty;
    for (lines.items[first..last], 0..) |line, index| {
        if (index != 0) try out.append(arena, '\n');
        if (line.len != 0) try out.appendSlice(arena, line[indent..]);
    }
    return out.toOwnedSlice(arena);
}

const Reader = struct {
    arena: Allocator,
    blocks: std.ArrayList(ir.Block) = .empty,
    params: std.ArrayList(Named) = .empty,
    type_params: std.ArrayList(Named) = .empty,
    returns: ir.Text = .{},
    raises: std.ArrayList(Named) = .empty,
    examples: std.ArrayList(ir.Example) = .empty,
    inherits: ?[]const u8 = null,

    fn flush(self: *Reader, loose: *std.ArrayList(Piece)) Allocator.Error!void {
        if (loose.items.len == 0) return;
        try self.blocks.appendSlice(self.arena, try self.blocksOf(loose.items));
        loose.clearRetainingCapacity();
    }

    fn blocksOf(self: *Reader, pieces: []const Piece) Allocator.Error![]const ir.Block {
        var out: std.ArrayList(ir.Block) = .empty;
        var line: std.ArrayList(ir.Inline) = .empty;
        for (pieces) |piece| switch (piece) {
            .text => |characters| {
                var paragraphs = std.mem.splitSequence(u8, characters, "\n\n");
                var first = true;
                while (paragraphs.next()) |part| {
                    if (!first) try self.paragraph(&out, &line);
                    first = false;
                    try self.words(&line, part);
                }
            },
            .element => |element| {
                if (is(element.name, "para")) {
                    try self.paragraph(&out, &line);
                    try out.appendSlice(self.arena, try self.blocksOf(element.children));
                } else if (is(element.name, "code")) {
                    try self.paragraph(&out, &line);
                    try out.append(self.arena, .{ .code = .{ .language = "csharp", .text = try verbatim(self.arena, element.children) } });
                } else if (is(element.name, "list")) {
                    try self.paragraph(&out, &line);
                    try out.append(self.arena, try self.list(element));
                } else {
                    try self.inlined(&line, element);
                }
            },
        };
        try self.paragraph(&out, &line);
        return out.toOwnedSlice(self.arena);
    }

    fn paragraph(self: *Reader, out: *std.ArrayList(ir.Block), line: *std.ArrayList(ir.Inline)) Allocator.Error!void {
        while (line.items.len != 0) {
            const last = &line.items[line.items.len - 1];
            if (last.* != .text) break;
            last.* = .{ .text = std.mem.trimEnd(u8, last.text, " ") };
            if (last.text.len != 0) break;
            _ = line.pop();
        }
        if (line.items.len == 0) return;
        try out.append(self.arena, .{ .paragraph = try line.toOwnedSlice(self.arena) });
    }

    fn words(self: *Reader, line: *std.ArrayList(ir.Inline), characters: []const u8) Allocator.Error!void {
        var out: std.ArrayList(u8) = .empty;
        var spaced = line.items.len == 0;
        if (line.items.len != 0 and line.items[line.items.len - 1] == .text) {
            try out.appendSlice(self.arena, line.pop().?.text);
            spaced = std.mem.endsWith(u8, out.items, " ");
        }
        for (characters) |ch| {
            if (std.ascii.isWhitespace(ch)) {
                if (!spaced) try out.append(self.arena, ' ');
                spaced = true;
            } else {
                try out.append(self.arena, ch);
                spaced = false;
            }
        }
        if (out.items.len != 0) try line.append(self.arena, .{ .text = try out.toOwnedSlice(self.arena) });
    }

    fn list(self: *Reader, element: Element) Allocator.Error!ir.Block {
        var items: std.ArrayList([]const ir.Block) = .empty;
        for (element.children) |child| {
            if (child != .element or !is(child.element.name, "item")) continue;
            var term: ?Element = null;
            var description: ?Element = null;
            for (child.element.children) |part| {
                if (part != .element) continue;
                if (is(part.element.name, "term")) term = part.element;
                if (is(part.element.name, "description")) description = part.element;
            }
            if (term == null and description == null) {
                try items.append(self.arena, try self.blocksOf(child.element.children));
                continue;
            }
            var joined: std.ArrayList(Piece) = .empty;
            if (term) |found| try joined.appendSlice(self.arena, found.children);
            if (term != null and description != null) try joined.append(self.arena, .{ .text = ": " });
            if (description) |found| try joined.appendSlice(self.arena, found.children);
            try items.append(self.arena, try self.blocksOf(joined.items));
        }
        return .{ .list = .{ .start = if (is(element.attribute("type"), "number")) 1 else null, .items = try items.toOwnedSlice(self.arena) } };
    }

    fn inlined(self: *Reader, line: *std.ArrayList(ir.Inline), element: Element) Allocator.Error!void {
        const name = element.name;
        if (is(name, "see") or is(name, "seealso")) {
            if (element.has("cref")) {
                try line.append(self.arena, try self.mention(element.attribute("cref")));
            } else if (element.has("langword")) {
                try line.append(self.arena, .{ .code = element.attribute("langword") });
            } else if (element.has("href")) {
                try self.link(line, element);
            } else try self.inside(line, element);
        } else if (is(name, "a") and element.has("href")) {
            try self.link(line, element);
        } else if (is(name, "paramref")) {
            try line.append(self.arena, .{ .param = element.attribute("name") });
        } else if (is(name, "typeparamref")) {
            try line.append(self.arena, .{ .code = element.attribute("name") });
        } else if (is(name, "c")) {
            const content = std.mem.trim(u8, try verbatim(self.arena, element.children), " ");
            if (content.len != 0) try line.append(self.arena, .{ .code = content });
        } else if (is(name, "b") or is(name, "strong")) {
            var content: std.ArrayList(ir.Inline) = .empty;
            try self.inside(&content, element);
            try line.append(self.arena, .{ .strong = try content.toOwnedSlice(self.arena) });
        } else if (is(name, "i") or is(name, "em")) {
            var content: std.ArrayList(ir.Inline) = .empty;
            try self.inside(&content, element);
            try line.append(self.arena, .{ .emphasis = try content.toOwnedSlice(self.arena) });
        } else if (is(name, "br")) {
            try line.append(self.arena, .line_break);
        } else try self.inside(line, element);
    }

    fn inside(self: *Reader, line: *std.ArrayList(ir.Inline), element: Element) Allocator.Error!void {
        for (element.children) |child| switch (child) {
            .text => |characters| try self.words(line, characters),
            .element => |nested| try self.inlined(line, nested),
        };
    }

    fn link(self: *Reader, line: *std.ArrayList(ir.Inline), element: Element) Allocator.Error!void {
        const url = element.attribute("href");
        var content: std.ArrayList(ir.Inline) = .empty;
        try self.inside(&content, element);
        if (content.items.len == 0) try content.append(self.arena, .{ .text = url });
        try line.append(self.arena, .{ .link = .{ .url = url, .content = try content.toOwnedSlice(self.arena) } });
    }

    fn mention(self: *Reader, cref: []const u8) Allocator.Error!ir.Inline {
        const name = try nameOf(self.arena, cref);
        return if (markdown_text.isName(name)) .{ .ref = .{ .text = name } } else .{ .code = cref };
    }
};

fn paragraphOf(block: ir.Block) []const ir.Inline {
    return block.paragraph;
}

test "the parts of a comment are told apart by the element that holds them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const comment = try parse(arena.allocator(),
        \\<summary>
        \\Waits for a task.
        \\</summary>
        \\<typeparam name="T">What the task yields.</typeparam>
        \\<param name="task">The task.</param>
        \\<param name="timeout">How long.</param>
        \\<returns>What it yielded.</returns>
        \\<exception cref="T:System.TimeoutException">When it took too long.</exception>
        \\<remarks>Never blocks a worker.</remarks>
    );
    try std.testing.expectEqual(2, comment.blocks.len);
    try std.testing.expectEqualStrings("Waits for a task.", paragraphOf(comment.blocks[0])[0].text);
    try std.testing.expectEqualStrings("Never blocks a worker.", paragraphOf(comment.blocks[1])[0].text);
    try std.testing.expectEqual(2, comment.params.len);
    try std.testing.expectEqualStrings("timeout", comment.params[1].name);
    try std.testing.expectEqualStrings("T", comment.type_params[0].name);
    try std.testing.expectEqualStrings("What it yielded.", paragraphOf(comment.returns.blocks[0])[0].text);
    try std.testing.expectEqualStrings("System.TimeoutException", comment.raises[0].name);
}

test "inline elements become mentions, code, parameters, stress and links" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const comment = try parse(arena.allocator(),
        \\<summary>Gives <paramref name="task"/> to a <see cref="Pool{T}.Run(int)"/>,
        \\never <see langword="null"/>, as <c>a &lt; b</c> or <b>now</b>.
        \\See <see href="https://example.org">the site</see>.</summary>
    );
    try std.testing.expectEqualDeep(@as([]const ir.Inline, &.{
        .{ .text = "Gives " },
        .{ .param = "task" },
        .{ .text = " to a " },
        .{ .ref = .{ .text = "Pool.Run" } },
        .{ .text = ", never " },
        .{ .code = "null" },
        .{ .text = ", as " },
        .{ .code = "a < b" },
        .{ .text = " or " },
        .{ .strong = &.{.{ .text = "now" }} },
        .{ .text = ". See " },
        .{ .link = .{ .url = "https://example.org", .content = &.{.{ .text = "the site" }} } },
        .{ .text = "." },
    }), paragraphOf(comment.blocks[0]));
}

test "paragraphs, code and lists are blocks, and the code of an example is an example" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const comment = try parse(arena.allocator(),
        \\<summary>
        \\<para>First.</para>
        \\<para>Second.</para>
        \\<code>
        \\    var a = 1;
        \\      a++;
        \\</code>
        \\<list type="number">
        \\<item><term>one</term><description>the first</description></item>
        \\<item>two</item>
        \\</list>
        \\</summary>
        \\<example>Used so:
        \\<code>pool.Run();</code>
        \\</example>
    );
    try std.testing.expectEqual(5, comment.blocks.len);
    try std.testing.expectEqualStrings("Second.", paragraphOf(comment.blocks[1])[0].text);
    try std.testing.expectEqualStrings("var a = 1;\n  a++;", comment.blocks[2].code.text);
    try std.testing.expectEqual(1, comment.blocks[3].list.start.?);
    try std.testing.expectEqualStrings("one: the first", paragraphOf(comment.blocks[3].list.items[0][0])[0].text);
    try std.testing.expectEqualStrings("Used so:", paragraphOf(comment.blocks[4])[0].text);
    try std.testing.expectEqualStrings("pool.Run();", comment.examples[0].code);
}

test "a comment without elements is documentation, and markup that is not well formed is read for what it holds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const plain = try parse(arena.allocator(), "True when a < b.");
    try std.testing.expectEqualStrings("True when a < b.", paragraphOf(plain.blocks[0])[0].text);
    try std.testing.expectEqual(null, plain.inherits);
    try std.testing.expectEqualStrings("", (try parse(arena.allocator(), "<inheritdoc/>")).inherits.?);
    try std.testing.expectEqualStrings("IPool.Run", (try parse(arena.allocator(), "<inheritdoc cref=\"IPool.Run(int)\"/>")).inherits.?);
    const open = try parse(arena.allocator(), "<summary>Left <c>open</summary><returns>Still read.</returns>");
    try std.testing.expectEqualStrings("Left ", paragraphOf(open.blocks[0])[0].text);
    try std.testing.expectEqualStrings("open", paragraphOf(open.blocks[0])[1].code);
    try std.testing.expectEqualStrings("Still read.", paragraphOf(open.returns.blocks[0])[0].text);
}
