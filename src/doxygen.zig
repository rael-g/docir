//! Reads the Doxygen comments of a C header.
//!
//! The reader does not parse C. It walks the text one declaration at a time: a declaration
//! ends at a `;` outside parentheses, at a `,` inside an enumeration, or at the `}` that
//! closes its braces. A braced declaration is a container, and its body is walked the same
//! way, so a documented field or vtable slot becomes a member of its struct. An
//! `extern "C"` block is transparent: what it holds belongs to the scope around it.
//!
//! A comment is documentation when it opens with `/**`, `/*!`, `///` or `//!`. It belongs to
//! the declaration that follows it, unless the marker is followed by `<`, in which case it
//! belongs to the declaration before it. A comment that carries `@file` documents the file.
//!
//! Inside a comment, `@brief`, `@param`, `@return` and their backslash forms are understood;
//! `@note`, `@warning` and the like become a labelled paragraph; `@c`, `@p`, `@a` and `@ref`
//! mark the next word as code.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

/// Extracts the documentation of one C header.
pub fn read(arena: Allocator, path: []const u8, source: []const u8) Allocator.Error!model.Unit {
    var reader: Reader = .{ .arena = arena, .source = source };
    var found: std.ArrayList(Candidate) = .empty;
    try reader.scope(if (std.mem.startsWith(u8, source, byte_order_mark)) byte_order_mark.len else 0, source.len, .statements, &found);
    var symbols: std.ArrayList([]const u8) = .empty;
    try reader.declare(found.items, "", &symbols);
    return .{
        .path = path,
        .language = "c",
        .intro = reader.intro,
        .entries = try reader.documented(found.items),
        .symbols = try symbols.toOwnedSlice(arena),
    };
}

const byte_order_mark = "\xEF\xBB\xBF";

const Kind = enum { statements, enumerators };

const Comment = struct {
    text: []const u8 = "",
    params: []const model.Param = &.{},
    returns: []const u8 = "",
    is_file: bool = false,

    fn isEmpty(self: Comment) bool {
        return self.text.len == 0 and self.params.len == 0 and self.returns.len == 0;
    }
};

const Candidate = struct {
    name: []const u8,
    signature: []const u8,
    doc: Comment = .{},
    members: []const model.Entry = &.{},
    children: []const Candidate = &.{},
};

const DocSpan = struct {
    end: usize,
    block: bool,
    trailing: bool,
};

const Reader = struct {
    arena: Allocator,
    source: []const u8,
    intro: []const u8 = "",

    fn scope(self: *Reader, start: usize, end: usize, kind: Kind, out: *std.ArrayList(Candidate)) Allocator.Error!void {
        const source = self.source;
        var at = start;
        var pending: ?Comment = null;
        while (true) {
            while (at < end and std.ascii.isWhitespace(source[at])) at += 1;
            if (at >= end) return;
            if (docSpan(source, at, end)) |span| {
                const comment = try parseComment(self.arena, source[at..span.end], span.block);
                if (comment.is_file) {
                    self.intro = comment.text;
                } else if (span.trailing) {
                    if (out.items.len != 0) try self.merge(&out.items[out.items.len - 1].doc, comment);
                } else {
                    pending = comment;
                }
                at = span.end;
                continue;
            }
            if (plainCommentEnd(source, at, end)) |next| {
                at = next;
                continue;
            }
            switch (source[at]) {
                '}', ';', ',' => at += 1,
                '#' => {
                    const line_end = directiveEnd(source, at, end);
                    const line = try normalize(self.arena, source[at..line_end]);
                    if (macroName(line)) |name| {
                        try out.append(self.arena, .{ .name = name, .signature = line, .doc = pending orelse .{} });
                        pending = null;
                    }
                    at = line_end;
                },
                else => {
                    at = try self.declaration(at, end, kind, pending orelse .{}, out);
                    pending = null;
                },
            }
        }
    }

    fn declaration(self: *Reader, start: usize, end: usize, kind: Kind, leading: Comment, out: *std.ArrayList(Candidate)) Allocator.Error!usize {
        const source = self.source;
        var doc = leading;
        var head: std.ArrayList(u8) = .empty;
        var depth: usize = 0;
        var at = start;
        while (at < end) {
            if (try self.skipComment(&at, end, &doc)) continue;
            const ch = source[at];
            if (ch == '(') depth += 1;
            if (ch == ')' and depth > 0) depth -= 1;
            if (depth == 0) {
                if (ch == '{') return self.braced(at, end, try normalize(self.arena, head.items), doc, out);
                if (ch == ';' or ch == '}' or (kind == .enumerators and ch == ',')) break;
            }
            try head.append(self.arena, ch);
            at += 1;
        }
        const signature = try normalize(self.arena, head.items);
        const name = switch (kind) {
            .enumerators => firstIdentifier(signature),
            .statements => declaredName(signature),
        };
        if (name.len != 0) try out.append(self.arena, .{ .name = name, .signature = signature, .doc = doc });
        return if (at < end and source[at] != '}') at + 1 else at;
    }

    fn braced(self: *Reader, open: usize, end: usize, head: []const u8, leading: Comment, out: *std.ArrayList(Candidate)) Allocator.Error!usize {
        const source = self.source;
        const close = matchingBrace(source, open, end);
        const after = @min(close + 1, end);
        if (std.mem.startsWith(u8, head, "extern") and std.mem.indexOfScalar(u8, head, '"') != null) {
            try self.scope(open + 1, close, .statements, out);
            return after;
        }
        if (std.mem.indexOfScalar(u8, head, '(') != null) {
            const name = declaredName(head);
            if (name.len != 0) try out.append(self.arena, .{ .name = name, .signature = head, .doc = leading });
            return after;
        }
        var inner: std.ArrayList(Candidate) = .empty;
        try self.scope(open + 1, close, if (hasWord(head, "enum")) .enumerators else .statements, &inner);

        var doc = leading;
        var tail: std.ArrayList(u8) = .empty;
        var at = after;
        while (at < end) {
            if (try self.skipComment(&at, end, &doc)) continue;
            if (source[at] == ';') {
                at += 1;
                break;
            }
            try tail.append(self.arena, source[at]);
            at += 1;
        }
        const alias = lastIdentifier(tail.items);
        const name = if (alias.len != 0) alias else lastIdentifier(head);
        if (name.len != 0) try out.append(self.arena, .{
            .name = name,
            .signature = head,
            .doc = doc,
            .members = try self.documented(inner.items),
            .children = inner.items,
        });
        return at;
    }

    fn skipComment(self: *Reader, at: *usize, end: usize, doc: *Comment) Allocator.Error!bool {
        if (docSpan(self.source, at.*, end)) |span| {
            if (span.trailing) try self.merge(doc, try parseComment(self.arena, self.source[at.*..span.end], span.block));
            at.* = span.end;
            return true;
        }
        if (plainCommentEnd(self.source, at.*, end)) |next| {
            at.* = next;
            return true;
        }
        return false;
    }

    fn merge(self: *Reader, into: *Comment, extra: Comment) Allocator.Error!void {
        if (extra.text.len != 0) {
            into.text = if (into.text.len == 0) extra.text else try std.mem.concat(self.arena, u8, &.{ into.text, "\n\n", extra.text });
        }
        if (extra.params.len != 0) into.params = try std.mem.concat(self.arena, model.Param, &.{ into.params, extra.params });
        if (extra.returns.len != 0) into.returns = extra.returns;
    }

    fn declare(self: *Reader, candidates: []const Candidate, prefix: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
        for (candidates) |candidate| {
            const qualified = if (prefix.len == 0) candidate.name else try std.mem.concat(self.arena, u8, &.{ prefix, ".", candidate.name });
            try out.append(self.arena, qualified);
            try self.declare(candidate.children, qualified, out);
        }
    }

    fn documented(self: *Reader, candidates: []const Candidate) Allocator.Error![]const model.Entry {
        var out: std.ArrayList(model.Entry) = .empty;
        for (candidates) |candidate| {
            if (candidate.doc.isEmpty() and candidate.members.len == 0) continue;
            try out.append(self.arena, .{
                .name = candidate.name,
                .signature = candidate.signature,
                .text = candidate.doc.text,
                .params = candidate.doc.params,
                .returns = candidate.doc.returns,
                .members = candidate.members,
            });
        }
        return out.toOwnedSlice(self.arena);
    }
};

fn docSpan(source: []const u8, at: usize, end: usize) ?DocSpan {
    const rest = source[at..end];
    if (rest.len < 4) return null;
    if (std.mem.startsWith(u8, rest, "/**") or std.mem.startsWith(u8, rest, "/*!")) {
        if (rest[3] == '*' or rest[3] == '/') return null;
        const close = std.mem.indexOfPos(u8, rest, 3, "*/") orelse return null;
        return .{ .end = at + close + 2, .block = true, .trailing = rest[3] == '<' };
    }
    if (!isLineDoc(rest)) return null;
    const trailing = rest[3] == '<';
    var line_end = lineEnd(source, at, end);
    while (true) {
        var next = line_end;
        while (next < end and (source[next] == '\n' or source[next] == '\r' or source[next] == ' ' or source[next] == '\t')) {
            if (source[next] == '\n' and next != line_end) break;
            next += 1;
        }
        if (next >= end or !isLineDoc(source[next..end]) or (source[next + 3] == '<') != trailing) break;
        line_end = lineEnd(source, next, end);
    }
    return .{ .end = line_end, .block = false, .trailing = trailing };
}

fn isLineDoc(rest: []const u8) bool {
    if (rest.len < 4) return false;
    if (std.mem.startsWith(u8, rest, "///")) return rest[3] != '/';
    return std.mem.startsWith(u8, rest, "//!");
}

fn plainCommentEnd(source: []const u8, at: usize, end: usize) ?usize {
    const rest = source[at..end];
    if (std.mem.startsWith(u8, rest, "//")) return lineEnd(source, at, end);
    if (std.mem.startsWith(u8, rest, "/*")) {
        const close = std.mem.indexOfPos(u8, rest, 2, "*/") orelse return end;
        return at + close + 2;
    }
    return null;
}

fn lineEnd(source: []const u8, at: usize, end: usize) usize {
    return std.mem.indexOfScalarPos(u8, source[0..end], at, '\n') orelse end;
}

fn directiveEnd(source: []const u8, start: usize, end: usize) usize {
    var at = start;
    while (at < end) : (at += 1) {
        if (source[at] == '\n') {
            const continued = at > start and (source[at - 1] == '\\' or (source[at - 1] == '\r' and at - 1 > start and source[at - 2] == '\\'));
            if (!continued) return at;
        }
        if (source[at] == '/' and at + 1 < end and (source[at + 1] == '/' or source[at + 1] == '*')) return at;
    }
    return end;
}

fn matchingBrace(source: []const u8, open: usize, end: usize) usize {
    var depth: usize = 0;
    var at = open;
    while (at < end) {
        if (plainCommentEnd(source, at, end)) |next| {
            at = next;
            continue;
        }
        if (source[at] == '{') depth += 1;
        if (source[at] == '}') {
            depth -= 1;
            if (depth == 0) return at;
        }
        at += 1;
    }
    return end;
}

fn normalize(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var gap = false;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == '\\') {
            gap = out.items.len != 0;
            continue;
        }
        if (gap) try out.append(arena, ' ');
        gap = false;
        try out.append(arena, ch);
    }
    return out.toOwnedSlice(arena);
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn firstIdentifier(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and !isIdentifierChar(text[start])) start += 1;
    var stop = start;
    while (stop < text.len and isIdentifierChar(text[stop])) stop += 1;
    return text[start..stop];
}

fn lastIdentifier(text: []const u8) []const u8 {
    var stop = text.len;
    while (stop > 0 and !isIdentifierChar(text[stop - 1])) stop -= 1;
    var start = stop;
    while (start > 0 and isIdentifierChar(text[start - 1])) start -= 1;
    return text[start..stop];
}

fn declaredName(signature: []const u8) []const u8 {
    if (std.mem.indexOf(u8, signature, "(*")) |pointer| return firstIdentifier(signature[pointer + 2 ..]);
    if (std.mem.indexOfScalar(u8, signature, '(')) |paren| return lastIdentifier(signature[0..paren]);
    var stop = signature.len;
    for ("=[:") |cut| {
        if (std.mem.indexOfScalar(u8, signature[0..stop], cut)) |found| stop = found;
    }
    return lastIdentifier(signature[0..stop]);
}

fn macroName(line: []const u8) ?[]const u8 {
    const rest = std.mem.trimStart(u8, line[1..], " ");
    if (!std.mem.startsWith(u8, rest, "define ")) return null;
    const name = firstIdentifier(rest["define ".len..]);
    return if (name.len == 0) null else name;
}

fn hasWord(text: []const u8, word: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, word)) |found| {
        const stop = found + word.len;
        const starts = found == 0 or !isIdentifierChar(text[found - 1]);
        const stops = stop == text.len or !isIdentifierChar(text[stop]);
        if (starts and stops) return true;
        at = stop;
    }
    return false;
}

const inline_code_commands = [_][]const u8{ "c", "p", "a", "ref" };
const paragraph_commands = [_]struct { command: []const u8, label: []const u8 }{
    .{ .command = "note", .label = "Note" },
    .{ .command = "warning", .label = "Warning" },
    .{ .command = "attention", .label = "Attention" },
    .{ .command = "see", .label = "See" },
    .{ .command = "sa", .label = "See" },
    .{ .command = "since", .label = "Since" },
    .{ .command = "deprecated", .label = "Deprecated" },
    .{ .command = "pre", .label = "Precondition" },
    .{ .command = "post", .label = "Postcondition" },
};

const CommentBuilder = struct {
    arena: Allocator,
    text: std.ArrayList(u8) = .empty,
    returns: std.ArrayList(u8) = .empty,
    params: std.ArrayList(ParamBuilder) = .empty,
    target: Target = .text,
    is_file: bool = false,

    const ParamBuilder = struct { name: []const u8, text: std.ArrayList(u8) = .empty };
    const Target = union(enum) { text, returns, param: usize };

    fn line(self: *CommentBuilder, raw: []const u8) Allocator.Error!void {
        const content = std.mem.trim(u8, raw, " \t\r");
        if (content.len == 0) {
            self.target = .text;
            if (self.text.items.len != 0) try self.text.append(self.arena, '\n');
            return;
        }
        const command = commandOf(content) orelse return self.add(content);
        const rest = std.mem.trimStart(u8, content[1 + command.len ..], " \t");
        for (inline_code_commands) |code| {
            if (std.mem.eql(u8, command, code)) return self.add(content);
        }
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
        for (paragraph_commands) |paragraph| {
            if (!std.mem.eql(u8, command, paragraph.command)) continue;
            self.target = .text;
            if (self.text.items.len != 0) try self.text.append(self.arena, '\n');
            return self.add(try std.fmt.allocPrint(self.arena, "**{s}:** {s}", .{ paragraph.label, rest }));
        }
        return self.add(content);
    }

    fn add(self: *CommentBuilder, content: []const u8) Allocator.Error!void {
        const buffer = switch (self.target) {
            .text => &self.text,
            .returns => &self.returns,
            .param => |index| &self.params.items[index].text,
        };
        if (content.len == 0) return;
        if (buffer.items.len != 0) try buffer.append(self.arena, if (self.target == .text) '\n' else ' ');
        try appendWithInlineCode(self.arena, buffer, content);
    }

    fn finish(self: *CommentBuilder) Allocator.Error!Comment {
        const params = try self.arena.alloc(model.Param, self.params.items.len);
        for (params, self.params.items) |*param, built| param.* = .{ .name = built.name, .text = built.text.items };
        return .{
            .text = std.mem.trim(u8, self.text.items, "\n"),
            .params = params,
            .returns = self.returns.items,
            .is_file = self.is_file,
        };
    }
};

fn commandOf(content: []const u8) ?[]const u8 {
    if (content.len < 2 or (content[0] != '@' and content[0] != '\\')) return null;
    var stop: usize = 1;
    while (stop < content.len and std.ascii.isAlphabetic(content[stop])) stop += 1;
    return if (stop == 1) null else content[1..stop];
}

fn appendWithInlineCode(arena: Allocator, buffer: *std.ArrayList(u8), content: []const u8) Allocator.Error!void {
    var at: usize = 0;
    outer: while (at < content.len) {
        if (content[at] == '@' or content[at] == '\\') {
            for (inline_code_commands) |code| {
                const word_start = at + 1 + code.len + 1;
                if (word_start >= content.len) continue;
                if (!std.mem.startsWith(u8, content[at + 1 ..], code) or content[word_start - 1] != ' ') continue;
                var word_end = word_start;
                while (word_end < content.len and !std.ascii.isWhitespace(content[word_end])) word_end += 1;
                while (word_end > word_start and std.mem.indexOfScalar(u8, ".,;:)", content[word_end - 1]) != null) word_end -= 1;
                if (word_end == word_start) continue;
                try buffer.append(arena, '`');
                try buffer.appendSlice(arena, content[word_start..word_end]);
                try buffer.append(arena, '`');
                at = word_end;
                continue :outer;
            }
        }
        try buffer.append(arena, content[at]);
        at += 1;
    }
}

fn parseComment(arena: Allocator, raw: []const u8, block: bool) Allocator.Error!Comment {
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

fn readForTest(arena: Allocator, source: []const u8) !model.Unit {
    return read(arena, "sample.h", source);
}

test "a documented function is named after the identifier before its parameters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/**
        \\ * @brief Creates a scheduler.
        \\ * @param out_error Receives the failure.
        \\ * @return Handle whose @c ref is NULL on failure.
        \\ */
        \\MY_API my_handle my_create(struct my_error **out_error);
        \\void undocumented(void);
    );
    try std.testing.expectEqual(1, unit.entries.len);
    const entry = unit.entries[0];
    try std.testing.expectEqualStrings("my_create", entry.name);
    try std.testing.expectEqualStrings("MY_API my_handle my_create(struct my_error **out_error)", entry.signature);
    try std.testing.expectEqualStrings("Creates a scheduler.", entry.text);
    try std.testing.expectEqualStrings("out_error", entry.params[0].name);
    try std.testing.expectEqualStrings("Receives the failure.", entry.params[0].text);
    try std.testing.expectEqualStrings("Handle whose `ref` is NULL on failure.", entry.returns);
}

test "the slots of a vtable become members named after the function pointer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/** Dispatches work. */
        \\typedef struct pool
        \\{
        \\    void *handle;
        \\    /**
        \\     * Schedules a task.
        \\     * @param func Entry point,
        \\     *             run on a worker.
        \\     */
        \\    task *(*dispatch)(struct pool *self,
        \\                      task_func func);
        \\    /** Counts the workers. */
        \\    uint32_t (*count)(struct pool *self);
        \\} pool;
    );
    try std.testing.expectEqual(1, unit.entries.len);
    const pool = unit.entries[0];
    try std.testing.expectEqualStrings("pool", pool.name);
    try std.testing.expectEqualStrings("typedef struct pool", pool.signature);
    try std.testing.expectEqualStrings("Dispatches work.", pool.text);
    try std.testing.expectEqual(2, pool.members.len);
    try std.testing.expectEqualStrings("dispatch", pool.members[0].name);
    try std.testing.expectEqualStrings("task *(*dispatch)(struct pool *self, task_func func)", pool.members[0].signature);
    try std.testing.expectEqualStrings("Entry point, run on a worker.", pool.members[0].params[0].text);
    try std.testing.expectEqualStrings("count", pool.members[1].name);
}

test "a callback typedef is named after the pointer it declares" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/// Body of a task.
        \\/// Runs on a worker.
        \\typedef void (*task_func)(void *data);
    );
    try std.testing.expectEqualStrings("task_func", unit.entries[0].name);
    try std.testing.expectEqualStrings("Body of a task.\nRuns on a worker.", unit.entries[0].text);
}

test "a trailing comment documents the declaration before it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\typedef struct params
        \\{
        \\    uint32_t width;  ///< Width in pixels.
        \\    uint32_t height; /**< Height in pixels. */
        \\    uint32_t depth;
        \\    char name[16];   ///< Shown in captures,
        \\                     ///< copied by the call.
        \\} params;
    );
    const members = unit.entries[0].members;
    try std.testing.expectEqual(3, members.len);
    try std.testing.expectEqualStrings("width", members[0].name);
    try std.testing.expectEqualStrings("Width in pixels.", members[0].text);
    try std.testing.expectEqualStrings("Height in pixels.", members[1].text);
    try std.testing.expectEqualStrings("name", members[2].name);
    try std.testing.expectEqualStrings("Shown in captures,\ncopied by the call.", members[2].text);
}

test "enumerators are split at commas and the last one needs none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/** How a face is culled. */
        \\typedef enum cull_mode
        \\{
        \\    CULL_NONE = 0, ///< Draws both faces.
        \\    /** Drops the back face. */
        \\    CULL_BACK = 1,
        \\    CULL_FRONT ///< Drops the front face.
        \\} cull_mode;
    );
    const members = unit.entries[0].members;
    try std.testing.expectEqual(3, members.len);
    try std.testing.expectEqualStrings("CULL_NONE", members[0].name);
    try std.testing.expectEqualStrings("CULL_BACK", members[1].name);
    try std.testing.expectEqualStrings("Drops the back face.", members[1].text);
    try std.testing.expectEqualStrings("CULL_FRONT", members[2].name);
    try std.testing.expectEqualStrings("Drops the front face.", members[2].text);
}

test "an extern block is transparent and include guards are not entries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\#ifndef GUARD_H_
        \\#define GUARD_H_
        \\#ifdef __cplusplus
        \\extern "C"
        \\{
        \\#endif
        \\    /** The answer. */
        \\    #define ANSWER 42
        \\    /** Stops the pool. */
        \\    void stop(void);
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\#endif
    );
    try std.testing.expectEqual(2, unit.entries.len);
    try std.testing.expectEqualStrings("ANSWER", unit.entries[0].name);
    try std.testing.expectEqualStrings("#define ANSWER 42", unit.entries[0].signature);
    try std.testing.expectEqualStrings("stop", unit.entries[1].name);
}

test "a file comment becomes the introduction and a note becomes a labelled paragraph" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/**
        \\ * @file sample.h
        \\ * Contracts of the pool.
        \\ */
        \\/**
        \\ * Waits for a task.
        \\ * @note Blocks the caller.
        \\ */
        \\bool wait(task *t);
    );
    try std.testing.expectEqualStrings("Contracts of the pool.", unit.intro);
    try std.testing.expectEqualStrings("Waits for a task.\n\n**Note:** Blocks the caller.", unit.entries[0].text);
}

test "plain comments and banner comments are not documentation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/* plain */
        \\int a;
        \\// plain
        \\int b;
        \\/*** banner ***/
        \\int c;
        \\//// banner
        \\int d;
    );
    try std.testing.expectEqual(0, unit.entries.len);
}

test "an inline function body is skipped and the next declaration is still read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/** Squares a number. */
        \\static inline int square(int x) { struct { int y; } s; s.y = x; return s.y * x; }
        \\/** Field count. */
        \\int count[4];
    );
    try std.testing.expectEqual(2, unit.entries.len);
    try std.testing.expectEqualStrings("square", unit.entries[0].name);
    try std.testing.expectEqualStrings("count", unit.entries[1].name);
}

test "every declaration is a symbol, documented or not, and a member is qualified by its container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\typedef struct task task;
        \\typedef struct handle
        \\{
        \\    task *ref;
        \\    void (*destroy)(task *self);
        \\} handle;
        \\#define LIMIT 4
    );
    const expected: []const []const u8 = &.{ "task", "handle", "handle.ref", "handle.destroy", "LIMIT" };
    try std.testing.expectEqual(expected.len, unit.symbols.len);
    for (expected, unit.symbols) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a byte order mark before the first directive is skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(), byte_order_mark ++
        \\#ifndef GUARD_H_
        \\extern "C"
        \\{
        \\    /** Stops the pool. */
        \\    void stop(void);
        \\}
        \\#endif
    );
    try std.testing.expectEqual(1, unit.symbols.len);
    try std.testing.expectEqualStrings("stop", unit.symbols[0]);
}
