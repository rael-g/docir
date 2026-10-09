//! Reads a documentation comment written the way Doxygen reads it.
//!
//! A comment is documentation when it opens with `/**`, `/*!`, `///` or `//!`, which is
//! what `shape` tells. When the marker is followed by `<` the comment is about the
//! declaration before it and not the one after.
//!
//! Inside a comment, `@brief`, `@param`, `@return` and their backslash forms are understood,
//! at the start of a line or after other text on it. `@note`, `@warning` and the like open
//! an `ir.Note` that runs to the next blank line. `@file` marks the comment as being about
//! the file. `@c` marks the next word as code, `@p` and `@a` as a parameter and `@ref` as a
//! mention of a symbol. The rest of the text is Markdown, as Doxygen accepts it, read by
//! `markdown_text`.
//!
//! No language is known here: which declaration a comment belongs to is for the reader of
//! that language to say.

const std = @import("std");
const ir = @import("ir.zig");
const markdown_text = @import("markdown_text.zig");

const Allocator = std.mem.Allocator;

/// What a comment says of one parameter.
pub const DocParam = struct {
    /// The name the comment gives the parameter.
    name: []const u8,
    /// What is said of it.
    text: ir.Text,
};

/// What was read from one comment.
pub const Comment = struct {
    /// The text, without what is said of parameters and of the value returned.
    blocks: []const ir.Block = &.{},
    /// What is said of each parameter, in the order of the comment.
    params: []const DocParam = &.{},
    /// What is said of the value returned.
    returns: ir.Text = .{},
    /// Whether the comment is about the file it is in.
    is_file: bool = false,
};

/// How a documentation comment is written.
pub const Shape = struct {
    /// Whether it is a `/** */` comment and not lines of `///`.
    block: bool,
    /// Whether it is about the declaration before it.
    trailing: bool,
};

/// The shape of the comment `text`, or null when it is not documentation: a plain comment,
/// or a banner such as `/*****/` and `////`.
pub fn shape(text: []const u8) ?Shape {
    const line: Shape = .{ .block = false, .trailing = false };
    if (std.mem.eql(u8, text, "///") or std.mem.eql(u8, text, "//!")) return line;
    if (text.len < 4) return null;
    if (std.mem.startsWith(u8, text, "/**") or std.mem.startsWith(u8, text, "/*!")) {
        if (text[3] == '*' or text[3] == '/') return null;
        return .{ .block = true, .trailing = text[3] == '<' };
    }
    if (std.mem.startsWith(u8, text, "///")) return if (text[3] == '/') null else .{ .block = false, .trailing = text[3] == '<' };
    if (std.mem.startsWith(u8, text, "//!")) return .{ .block = false, .trailing = text[3] == '<' };
    return null;
}

const Mention = enum { code, param, symbol };

const inline_commands = std.StaticStringMap(Mention).initComptime(.{
    .{ "c", .code },
    .{ "p", .param },
    .{ "a", .param },
    .{ "ref", .symbol },
});

const note_commands = std.StaticStringMap([]const u8).initComptime(.{
    .{ "note", "note" },
    .{ "warning", "warning" },
    .{ "attention", "attention" },
    .{ "see", "see" },
    .{ "sa", "see" },
    .{ "since", "since" },
    .{ "deprecated", "deprecated" },
    .{ "pre", "precondition" },
    .{ "post", "postcondition" },
});

const CommentBuilder = struct {
    arena: Allocator,
    segments: std.ArrayList(Segment) = .empty,
    returns: std.ArrayList(u8) = .empty,
    params: std.ArrayList(ParamBuilder) = .empty,
    marked: std.StringHashMapUnmanaged(Mention) = .empty,
    target: Target = .text,
    is_file: bool = false,

    const Segment = struct { label: []const u8 = "", text: std.ArrayList(u8) = .empty };
    const ParamBuilder = struct { name: []const u8, text: std.ArrayList(u8) = .empty };
    const Target = union(enum) { text, returns, param: usize };

    fn line(self: *CommentBuilder, raw: []const u8) Allocator.Error!void {
        const content = std.mem.trim(u8, raw, " \t\r");
        if (content.len == 0) {
            self.target = .text;
            const last = self.segments.items.len;
            if (last != 0 and self.segments.items[last - 1].label.len != 0) {
                try self.segments.append(self.arena, .{});
            } else if (last != 0 and self.segments.items[last - 1].text.items.len != 0) {
                try self.segments.items[last - 1].text.append(self.arena, '\n');
            }
            return;
        }
        if (nextCommand(content)) |at| {
            try self.line(content[0..at]);
            return self.line(content[at..]);
        }
        const command = commandOf(content) orelse return self.add(content);
        const rest = std.mem.trimStart(u8, content[1 + command.len ..], " \t");
        if (inline_commands.has(command)) return self.add(content);
        if (std.mem.eql(u8, command, "brief") or std.mem.eql(u8, command, "short") or std.mem.eql(u8, command, "details")) {
            self.target = .text;
            return self.add(rest);
        }
        if (std.mem.eql(u8, command, "file")) {
            self.is_file = true;
            self.target = .text;
            return;
        }
        if (std.mem.eql(u8, command, "return") or std.mem.eql(u8, command, "returns") or std.mem.eql(u8, command, "retval")) {
            self.target = .returns;
            return self.add(rest);
        }
        if (std.mem.eql(u8, command, "param") or std.mem.eql(u8, command, "tparam")) {
            var named = rest;
            if (std.mem.startsWith(u8, named, "[")) {
                const close = std.mem.indexOfScalar(u8, named, ']') orelse named.len - 1;
                named = std.mem.trimStart(u8, named[close + 1 ..], " \t");
            }
            const name_end = std.mem.indexOfAny(u8, named, " \t") orelse named.len;
            try self.params.append(self.arena, .{ .name = named[0..name_end] });
            self.target = .{ .param = self.params.items.len - 1 };
            return self.add(std.mem.trimStart(u8, named[name_end..], " \t"));
        }
        if (note_commands.get(command)) |label| {
            self.target = .text;
            try self.segments.append(self.arena, .{ .label = label });
            return self.add(rest);
        }
        return self.add(content);
    }

    fn add(self: *CommentBuilder, content: []const u8) Allocator.Error!void {
        if (content.len == 0) return;
        const buffer = switch (self.target) {
            .text => text: {
                if (self.segments.items.len == 0) try self.segments.append(self.arena, .{});
                break :text &self.segments.items[self.segments.items.len - 1].text;
            },
            .returns => &self.returns,
            .param => |index| &self.params.items[index].text,
        };
        if (buffer.items.len != 0) try buffer.append(self.arena, if (self.target == .text) '\n' else ' ');
        try self.appendMarked(buffer, content);
    }

    fn appendMarked(self: *CommentBuilder, buffer: *std.ArrayList(u8), content: []const u8) Allocator.Error!void {
        var at: usize = 0;
        while (at < content.len) {
            if (content[at] == '@' or content[at] == '\\') {
                if (commandOf(content[at..])) |command| {
                    const word_start = at + 1 + command.len + 1;
                    if (inline_commands.get(command)) |mention| {
                        if (word_start < content.len and content[word_start - 1] == ' ') {
                            var word_end = word_start;
                            while (word_end < content.len and !std.ascii.isWhitespace(content[word_end])) word_end += 1;
                            while (word_end > word_start and std.mem.indexOfScalar(u8, ".,;:)", content[word_end - 1]) != null) word_end -= 1;
                            if (word_end != word_start) {
                                const word = content[word_start..word_end];
                                try self.marked.put(self.arena, word, mention);
                                try buffer.append(self.arena, '`');
                                try buffer.appendSlice(self.arena, word);
                                try buffer.append(self.arena, '`');
                                at = word_end;
                                continue;
                            }
                        }
                    }
                }
            }
            try buffer.append(self.arena, content[at]);
            at += 1;
        }
    }

    fn read(self: *CommentBuilder, source: []const u8) Allocator.Error![]const ir.Block {
        return self.blocks((try markdown_text.parse(self.arena, source)).blocks);
    }

    fn blocks(self: *CommentBuilder, list: []const ir.Block) Allocator.Error![]const ir.Block {
        const out = try self.arena.dupe(ir.Block, list);
        for (out) |*block| switch (block.*) {
            .paragraph => |content| block.* = .{ .paragraph = try self.inlines(content) },
            .heading => |heading| block.* = .{ .heading = .{ .level = heading.level, .content = try self.inlines(heading.content) } },
            .list => |listed| {
                const items = try self.arena.dupe([]const ir.Block, listed.items);
                for (items) |*item| item.* = try self.blocks(item.*);
                block.* = .{ .list = .{ .start = listed.start, .items = items } };
            },
            .quote => |quoted| block.* = .{ .quote = try self.blocks(quoted) },
            .note => |note| block.* = .{ .note = .{ .label = note.label, .blocks = try self.blocks(note.blocks) } },
            .table => |table| {
                const header = try self.arena.dupe([]const ir.Inline, table.header);
                for (header) |*cell| cell.* = try self.inlines(cell.*);
                const rows = try self.arena.dupe([]const []const ir.Inline, table.rows);
                for (rows) |*row| {
                    const cells = try self.arena.dupe([]const ir.Inline, row.*);
                    for (cells) |*cell| cell.* = try self.inlines(cell.*);
                    row.* = cells;
                }
                block.* = .{ .table = .{ .header = header, .rows = rows } };
            },
            .code, .rule => {},
        };
        return out;
    }

    fn inlines(self: *CommentBuilder, list: []const ir.Inline) Allocator.Error![]const ir.Inline {
        const out = try self.arena.dupe(ir.Inline, list);
        for (out) |*piece| switch (piece.*) {
            .ref => |ref| if (self.marked.get(ref.text)) |mention| switch (mention) {
                .code => piece.* = .{ .code = ref.text },
                .param => piece.* = .{ .param = ref.text },
                .symbol => {},
            },
            .emphasis => |content| piece.* = .{ .emphasis = try self.inlines(content) },
            .strong => |content| piece.* = .{ .strong = try self.inlines(content) },
            .link => |link| piece.* = .{ .link = .{ .url = link.url, .content = try self.inlines(link.content) } },
            else => {},
        };
        return out;
    }

    fn finish(self: *CommentBuilder) Allocator.Error!Comment {
        var text: std.ArrayList(ir.Block) = .empty;
        for (self.segments.items) |segment| {
            const read_blocks = try self.read(segment.text.items);
            if (read_blocks.len == 0) continue;
            if (segment.label.len == 0) {
                try text.appendSlice(self.arena, read_blocks);
            } else {
                try text.append(self.arena, .{ .note = .{ .label = segment.label, .blocks = read_blocks } });
            }
        }
        const params = try self.arena.alloc(DocParam, self.params.items.len);
        for (params, self.params.items) |*param, built| param.* = .{ .name = built.name, .text = .{ .blocks = try self.read(built.text.items) } };
        return .{
            .blocks = try text.toOwnedSlice(self.arena),
            .params = params,
            .returns = .{ .blocks = try self.read(self.returns.items) },
            .is_file = self.is_file,
        };
    }
};

const block_commands = std.StaticStringMap(void).initComptime(.{
    .{"param"}, .{"tparam"}, .{"return"}, .{"returns"}, .{"retval"}, .{"brief"}, .{"details"},
});

fn nextCommand(content: []const u8) ?usize {
    var at: usize = 1;
    while (at < content.len) : (at += 1) {
        if (content[at] != '@' and content[at] != '\\') continue;
        if (content[at - 1] != ' ' and content[at - 1] != '\t') continue;
        const command = commandOf(content[at..]) orelse continue;
        if (block_commands.has(command) or note_commands.has(command)) return at;
    }
    return null;
}

fn commandOf(content: []const u8) ?[]const u8 {
    if (content.len < 2 or (content[0] != '@' and content[0] != '\\')) return null;
    var stop: usize = 1;
    while (stop < content.len and std.ascii.isAlphabetic(content[stop])) stop += 1;
    return if (stop == 1) null else content[1..stop];
}

/// Reads the documentation comment `raw`, which is the whole comment with its markers. A
/// comment written as several lines of `///` or `//!` is given as those lines, one after
/// another. `block` says whether it is a `/** */` comment.
pub fn parse(arena: Allocator, raw: []const u8, block: bool) Allocator.Error!Comment {
    var builder: CommentBuilder = .{ .arena = arena };
    var body = raw;
    if (block) {
        body = body[3 .. body.len - 2];
        if (std.mem.startsWith(u8, body, "<")) body = body[1..];
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        var content = std.mem.trim(u8, raw_line, " \t\r");
        if (block) {
            if (std.mem.startsWith(u8, content, "*")) content = content[1..];
        } else {
            content = content[3..];
            if (std.mem.startsWith(u8, content, "<")) content = content[1..];
        }
        try builder.line(content);
    }
    return builder.finish();
}

fn plain(arena: Allocator, text: ir.Text) ![]const u8 {
    return ir.plainText(arena, text);
}

test "a comment is documentation by the way it opens" {
    try std.testing.expectEqual(Shape{ .block = true, .trailing = false }, shape("/** x */").?);
    try std.testing.expectEqual(Shape{ .block = true, .trailing = true }, shape("/**< x */").?);
    try std.testing.expectEqual(Shape{ .block = false, .trailing = false }, shape("/// x").?);
    try std.testing.expectEqual(Shape{ .block = false, .trailing = true }, shape("///< x").?);
    try std.testing.expectEqual(Shape{ .block = false, .trailing = false }, shape("//! x").?);
    try std.testing.expectEqual(Shape{ .block = false, .trailing = false }, shape("///").?);
    try std.testing.expectEqual(null, shape("/* x */"));
    try std.testing.expectEqual(null, shape("// x"));
    try std.testing.expectEqual(null, shape("/*** x ***/"));
    try std.testing.expectEqual(null, shape("//// x"));
}

test "parameters, the value returned and notes are taken out of the text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const comment = try parse(arena.allocator(),
        \\/**
        \\ * @brief Waits for a task.
        \\ * @note Blocks the caller.
        \\ *
        \\ * @param[in] t The task,
        \\ *              never null.
        \\ * @param out_x [out] @param out_y [out]
        \\ * @return Whether it ended. @retval false On failure.
        \\ */
    , true);
    try std.testing.expectEqual(2, comment.blocks.len);
    try std.testing.expectEqualDeep(ir.Block{ .paragraph = &.{.{ .text = "Waits for a task." }} }, comment.blocks[0]);
    try std.testing.expectEqualDeep(ir.Block{ .note = .{ .label = "note", .blocks = &.{.{ .paragraph = &.{.{ .text = "Blocks the caller." }} }} } }, comment.blocks[1]);
    try std.testing.expectEqual(3, comment.params.len);
    try std.testing.expectEqualStrings("t", comment.params[0].name);
    try std.testing.expectEqualStrings("The task, never null.", try plain(arena.allocator(), comment.params[0].text));
    try std.testing.expectEqualStrings("out_x", comment.params[1].name);
    try std.testing.expectEqualStrings("out_y", comment.params[2].name);
    try std.testing.expectEqualStrings("[out]", try plain(arena.allocator(), comment.params[2].text));
    try std.testing.expectEqualStrings("Whether it ended. false On failure.", try plain(arena.allocator(), comment.returns));
    try std.testing.expect(!comment.is_file);
}

test "lines of comment are one comment, and one that names the file is about the file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const comment = try parse(arena.allocator(), "/// @file pool.h\n/// Body of a task.\n/// Runs on a worker.", false);
    try std.testing.expect(comment.is_file);
    try std.testing.expectEqualStrings("Body of a task.\nRuns on a worker.", try plain(arena.allocator(), .{ .blocks = comment.blocks }));
}

test "the word after an inline command is code, a parameter or a mention" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const comment = try parse(arena.allocator(), "/** Sets @p count, never @c NULL, like @ref grow and `shrink`. */", true);
    try std.testing.expectEqualDeep(@as([]const ir.Inline, &.{
        .{ .text = "Sets " },
        .{ .param = "count" },
        .{ .text = ", never " },
        .{ .code = "NULL" },
        .{ .text = ", like " },
        .{ .ref = .{ .text = "grow" } },
        .{ .text = " and " },
        .{ .ref = .{ .text = "shrink" } },
        .{ .text = "." },
    }), comment.blocks[0].paragraph);
}
