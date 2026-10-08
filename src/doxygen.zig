//! Reads the Doxygen comments and the declarations of a C header.
//!
//! The reader does not parse C. It walks the text one declaration at a time: a declaration
//! ends at a `;` outside parentheses, at a `,` inside an enumeration, or at the `}` that
//! closes its braces. A braced declaration is a container, and its body is walked the same
//! way, so a field or a vtable slot becomes a member of its struct. An `extern "C"` block
//! is transparent: what it holds belongs to the scope around it. Every declaration is
//! recorded, documented or not, and every `#include` is listed as an import.
//!
//! A comment is documentation when it opens with `/**`, `/*!`, `///` or `//!`. It belongs to
//! the declaration that follows it, unless the marker is followed by `<`, in which case it
//! belongs to the declaration before it. A comment that carries `@file` documents the file.
//!
//! Inside a comment, `@brief`, `@param`, `@return` and their backslash forms are understood;
//! `@note`, `@warning` and the like become a labelled paragraph; `@c`, `@p`, `@a` and `@ref`
//! mark the next word as code.
//!
//! The parameters of a function, of a function pointer and of a callback type are taken
//! from its signature, with name and type, and each `@param` is attached to the parameter
//! it names. A `@param` that names no parameter is kept, with no type.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

/// Extracts one C header. `path` becomes the path of the file in the document and the
/// first part of the identifier of each declaration.
pub fn read(arena: Allocator, path: []const u8, source: []const u8) Allocator.Error!model.File {
    var line_starts: std.ArrayList(usize) = .empty;
    try line_starts.append(arena, 0);
    for (source, 0..) |ch, offset| {
        if (ch == '\n') try line_starts.append(arena, offset + 1);
    }

    var reader: Reader = .{ .arena = arena, .source = source, .path = path, .line_starts = line_starts.items };
    var found: std.ArrayList(Candidate) = .empty;
    const start: usize = if (std.mem.startsWith(u8, source, byte_order_mark)) byte_order_mark.len else 0;
    try reader.scope(start, source.len, .statements, false, &found);
    return .{
        .path = path,
        .language = .c,
        .doc = .{ .markdown = reader.intro },
        .imports = try reader.imports.toOwnedSlice(arena),
        .decls = try reader.decls(found.items, ""),
    };
}

const byte_order_mark = "\xEF\xBB\xBF";

const Scope = enum { statements, enumerators };

const DocParam = struct {
    name: []const u8,
    text: []const u8,
};

const Comment = struct {
    text: []const u8 = "",
    params: []const DocParam = &.{},
    returns: []const u8 = "",
    is_file: bool = false,
};

const Candidate = struct {
    name: []const u8,
    signature: []const u8,
    kind: model.Kind,
    start: usize,
    end: usize,
    doc: Comment = .{},
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
    path: []const u8,
    line_starts: []const usize,
    intro: []const u8 = "",
    imports: std.ArrayList(model.Import) = .empty,

    fn lineOf(self: *Reader, offset: usize) u32 {
        var low: usize = 0;
        var high: usize = self.line_starts.len;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (self.line_starts[middle] <= offset) low = middle else high = middle;
        }
        return @intCast(low + 1);
    }

    fn scope(self: *Reader, start: usize, end: usize, kind: Scope, member: bool, out: *std.ArrayList(Candidate)) Allocator.Error!void {
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
                    if (includedName(line)) |name| try self.imports.append(self.arena, .{ .name = name, .kind = .include });
                    if (macroName(line)) |name| {
                        try out.append(self.arena, .{ .name = name, .signature = line, .kind = .macro, .start = at, .end = line_end, .doc = pending orelse .{} });
                        pending = null;
                    }
                    at = line_end;
                },
                else => {
                    at = try self.declaration(at, end, kind, member, pending orelse .{}, out);
                    pending = null;
                },
            }
        }
    }

    fn declaration(self: *Reader, start: usize, end: usize, kind: Scope, member: bool, leading: Comment, out: *std.ArrayList(Candidate)) Allocator.Error!usize {
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
                if (ch == '{') return self.braced(start, at, end, try normalize(self.arena, head.items), member, doc, out);
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
        if (name.len != 0) try out.append(self.arena, .{
            .name = name,
            .signature = signature,
            .kind = switch (kind) {
                .enumerators => .enumerator,
                .statements => if (member) .field else topLevelKind(signature),
            },
            .start = start,
            .end = at,
            .doc = doc,
        });
        return if (at < end and source[at] != '}') at + 1 else at;
    }

    fn braced(self: *Reader, start: usize, open: usize, end: usize, head: []const u8, member: bool, leading: Comment, out: *std.ArrayList(Candidate)) Allocator.Error!usize {
        const source = self.source;
        const close = matchingBrace(source, open, end);
        const after = @min(close + 1, end);
        if (std.mem.startsWith(u8, head, "extern") and std.mem.indexOfScalar(u8, head, '"') != null) {
            try self.scope(open + 1, close, .statements, member, out);
            return after;
        }
        if (std.mem.indexOfScalar(u8, head, '(') != null) {
            const name = declaredName(head);
            if (name.len != 0) try out.append(self.arena, .{ .name = name, .signature = head, .kind = .function, .start = start, .end = close, .doc = leading });
            return after;
        }
        const container: model.Kind = if (hasWord(head, "enum")) .@"enum" else if (hasWord(head, "union")) .@"union" else .@"struct";
        var inner: std.ArrayList(Candidate) = .empty;
        try self.scope(open + 1, close, if (container == .@"enum") .enumerators else .statements, true, &inner);

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
            .kind = container,
            .start = start,
            .end = close,
            .doc = doc,
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
        if (extra.params.len != 0) into.params = try std.mem.concat(self.arena, DocParam, &.{ into.params, extra.params });
        if (extra.returns.len != 0) into.returns = extra.returns;
    }

    fn decls(self: *Reader, candidates: []const Candidate, prefix: []const u8) Allocator.Error![]const model.Decl {
        const out = try self.arena.alloc(model.Decl, candidates.len);
        for (out, candidates) |*decl, candidate| {
            const qualified = if (prefix.len == 0) candidate.name else try std.mem.concat(self.arena, u8, &.{ prefix, ".", candidate.name });
            const signature = candidate.signature;
            const function_like = isFunctionLike(candidate.kind, signature);
            decl.* = .{
                .id = try std.mem.concat(self.arena, u8, &.{ self.path, "#", qualified }),
                .name = candidate.name,
                .kind = candidate.kind,
                .line = self.lineOf(candidate.start),
                .end_line = self.lineOf(candidate.end),
                .signature = signature,
                .doc = .{ .markdown = candidate.doc.text },
                .params = try self.params(if (function_like) signature else "", candidate.doc.params),
                .return_type = if (function_like) returnType(signature, candidate.name) else "",
                .returns = .{ .markdown = candidate.doc.returns },
                .type_name = if (candidate.kind == .field and !function_like) try withoutName(self.arena, signature, candidate.name) else "",
                .value = if (candidate.kind == .enumerator) valueOf(signature) else "",
                .members = try self.decls(candidate.children, qualified),
            };
        }
        return out;
    }

    fn params(self: *Reader, signature: []const u8, documented: []const DocParam) Allocator.Error![]const model.Param {
        var out: std.ArrayList(model.Param) = .empty;
        if (parameterList(signature)) |list| {
            var depth: usize = 0;
            var piece_start: usize = 0;
            for (list, 0..) |ch, index| {
                if (ch == '(' or ch == '[') depth += 1;
                if ((ch == ')' or ch == ']') and depth > 0) depth -= 1;
                if (ch == ',' and depth == 0) {
                    try self.param(&out, list[piece_start..index]);
                    piece_start = index + 1;
                }
            }
            try self.param(&out, list[piece_start..]);
        }
        next: for (documented) |doc| {
            for (out.items) |*existing| {
                if (!std.mem.eql(u8, existing.name, doc.name)) continue;
                existing.doc = .{ .markdown = doc.text };
                continue :next;
            }
            try out.append(self.arena, .{ .name = doc.name, .doc = .{ .markdown = doc.text } });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn param(self: *Reader, out: *std.ArrayList(model.Param), piece: []const u8) Allocator.Error!void {
        const text = std.mem.trim(u8, piece, " ");
        if (text.len == 0 or std.mem.eql(u8, text, "void")) return;
        if (std.mem.indexOf(u8, text, "(*") != null) return out.append(self.arena, .{ .name = declaredName(text), .type_name = text });
        const name = declaredName(text);
        const unnamed = name.len == 0 or name.len == text.len or std.mem.endsWith(u8, text, "*") or identifierCount(text) < 2;
        if (unnamed) return out.append(self.arena, .{ .name = "", .type_name = text });
        try out.append(self.arena, .{ .name = name, .type_name = try withoutName(self.arena, text, name) });
    }
};

fn topLevelKind(signature: []const u8) model.Kind {
    if (std.mem.startsWith(u8, signature, "typedef")) return .typedef;
    if (std.mem.indexOfScalar(u8, signature, '(') != null) return .function;
    inline for (.{ .{ "struct ", .@"struct" }, .{ "union ", .@"union" }, .{ "enum ", .@"enum" } }) |pair| {
        if (std.mem.startsWith(u8, signature, pair[0])) return pair[1];
    }
    return .variable;
}

fn isFunctionLike(kind: model.Kind, signature: []const u8) bool {
    return switch (kind) {
        .function, .typedef, .field => std.mem.indexOfScalar(u8, signature, '(') != null,
        else => false,
    };
}

fn parameterList(signature: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var open: usize = 0;
    var list: ?[]const u8 = null;
    for (signature, 0..) |ch, index| {
        if (ch == '(') {
            if (depth == 0) open = index;
            depth += 1;
        }
        if (ch == ')' and depth > 0) {
            depth -= 1;
            if (depth == 0) list = signature[open + 1 .. index];
        }
    }
    return list;
}

fn returnType(signature: []const u8, name: []const u8) []const u8 {
    const stop = std.mem.indexOf(u8, signature, "(*") orelse offsetOf(signature, name) orelse return "";
    var result = std.mem.trim(u8, signature[0..stop], " ");
    if (std.mem.startsWith(u8, result, "typedef ")) result = result["typedef ".len..];
    return result;
}

fn offsetOf(haystack: []const u8, name: []const u8) ?usize {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, name)) |found| {
        const stop = found + name.len;
        const starts = found == 0 or !isIdentifierChar(haystack[found - 1]);
        const stops = stop == haystack.len or !isIdentifierChar(haystack[stop]);
        if (starts and stops) return found;
        at = found + 1;
    }
    return null;
}

fn withoutName(arena: Allocator, text: []const u8, name: []const u8) Allocator.Error![]const u8 {
    var cut = text;
    if (std.mem.indexOfScalar(u8, cut, '=')) |assign| cut = cut[0..assign];
    var last: ?usize = null;
    var at: usize = 0;
    while (offsetOf(cut[at..], name)) |found| {
        last = at + found;
        at = at + found + name.len;
    }
    const position = last orelse return std.mem.trim(u8, cut, " ");
    const before = std.mem.trimEnd(u8, cut[0..position], " ");
    const after = std.mem.trim(u8, cut[position + name.len ..], " ");
    return std.mem.concat(arena, u8, &.{ before, after });
}

fn valueOf(signature: []const u8) []const u8 {
    const assign = std.mem.indexOfScalar(u8, signature, '=') orelse return "";
    return std.mem.trim(u8, signature[assign + 1 ..], " ");
}

fn identifierCount(text: []const u8) usize {
    var count: usize = 0;
    var inside = false;
    for (text) |ch| {
        const now = isIdentifierChar(ch);
        if (now and !inside) count += 1;
        inside = now;
    }
    return count;
}

fn includedName(line: []const u8) ?[]const u8 {
    const rest = std.mem.trimStart(u8, line[1..], " ");
    if (!std.mem.startsWith(u8, rest, "include")) return null;
    const name = std.mem.trim(u8, rest["include".len..], " <>\"");
    return if (name.len == 0) null else name;
}

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
        const params = try self.arena.alloc(DocParam, self.params.items.len);
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

fn readForTest(arena: Allocator, source: []const u8) !model.File {
    return read(arena, "sample.h", source);
}

test "a function carries its name, parameters, return type and documentation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/**
        \\ * @brief Creates a scheduler.
        \\ * @param out_error Receives the failure.
        \\ * @return Handle whose @c ref is NULL on failure.
        \\ */
        \\MY_API my_handle my_create(uint32_t workers, struct my_error **out_error);
        \\void undocumented(void);
    );
    try std.testing.expectEqual(2, file.decls.len);
    const create = file.decls[0];
    try std.testing.expectEqualStrings("sample.h#my_create", create.id);
    try std.testing.expectEqual(model.Kind.function, create.kind);
    try std.testing.expectEqual(6, create.line);
    try std.testing.expectEqualStrings("MY_API my_handle my_create(uint32_t workers, struct my_error **out_error)", create.signature);
    try std.testing.expectEqualStrings("MY_API my_handle", create.return_type);
    try std.testing.expectEqualStrings("Creates a scheduler.", create.doc.markdown);
    try std.testing.expectEqual(2, create.params.len);
    try std.testing.expectEqualStrings("workers", create.params[0].name);
    try std.testing.expectEqualStrings("uint32_t", create.params[0].type_name);
    try std.testing.expectEqualStrings("", create.params[0].doc.markdown);
    try std.testing.expectEqualStrings("out_error", create.params[1].name);
    try std.testing.expectEqualStrings("struct my_error **", create.params[1].type_name);
    try std.testing.expectEqualStrings("Receives the failure.", create.params[1].doc.markdown);
    try std.testing.expectEqualStrings("Handle whose `ref` is NULL on failure.", create.returns.markdown);
    try std.testing.expectEqual(0, file.decls[1].params.len);
    try std.testing.expectEqualStrings("void", file.decls[1].return_type);
}

test "the slots of a vtable are members named after the function pointer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
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
        \\    uint32_t (*count)(struct pool *self);
        \\} pool;
    );
    try std.testing.expectEqual(1, file.decls.len);
    const pool = file.decls[0];
    try std.testing.expectEqual(model.Kind.@"struct", pool.kind);
    try std.testing.expectEqualStrings("typedef struct pool", pool.signature);
    try std.testing.expectEqualStrings("Dispatches work.", pool.doc.markdown);
    try std.testing.expectEqual(2, pool.line);
    try std.testing.expectEqual(13, pool.end_line);
    try std.testing.expectEqual(3, pool.members.len);
    try std.testing.expectEqualStrings("void *", pool.members[0].type_name);
    const dispatch = pool.members[1];
    try std.testing.expectEqualStrings("sample.h#pool.dispatch", dispatch.id);
    try std.testing.expectEqual(model.Kind.field, dispatch.kind);
    try std.testing.expectEqualStrings("task *(*dispatch)(struct pool *self, task_func func)", dispatch.signature);
    try std.testing.expectEqualStrings("task *", dispatch.return_type);
    try std.testing.expectEqualStrings("self", dispatch.params[0].name);
    try std.testing.expectEqualStrings("struct pool *", dispatch.params[0].type_name);
    try std.testing.expectEqualStrings("Entry point, run on a worker.", dispatch.params[1].doc.markdown);
    try std.testing.expectEqualStrings("count", pool.members[2].name);
}

test "a callback typedef is named after the pointer it declares" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/// Body of a task.
        \\/// Runs on a worker.
        \\typedef void (*task_func)(void *data, void (*done)(int code));
        \\typedef struct task task;
    );
    const callback = file.decls[0];
    try std.testing.expectEqual(model.Kind.typedef, callback.kind);
    try std.testing.expectEqualStrings("task_func", callback.name);
    try std.testing.expectEqualStrings("void", callback.return_type);
    try std.testing.expectEqualStrings("Body of a task.\nRuns on a worker.", callback.doc.markdown);
    try std.testing.expectEqual(2, callback.params.len);
    try std.testing.expectEqualStrings("done", callback.params[1].name);
    try std.testing.expectEqualStrings("void (*done)(int code)", callback.params[1].type_name);
    try std.testing.expectEqualStrings("task", file.decls[1].name);
}

test "a trailing comment documents the declaration before it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\typedef struct params
        \\{
        \\    uint32_t width;  ///< Width in pixels.
        \\    uint32_t height; /**< Height in pixels. */
        \\    uint32_t depth;
        \\    char name[16];   ///< Shown in captures,
        \\                     ///< copied by the call.
        \\} params;
    );
    const members = file.decls[0].members;
    try std.testing.expectEqual(4, members.len);
    try std.testing.expectEqualStrings("width", members[0].name);
    try std.testing.expectEqualStrings("Width in pixels.", members[0].doc.markdown);
    try std.testing.expectEqualStrings("Height in pixels.", members[1].doc.markdown);
    try std.testing.expectEqualStrings("", members[2].doc.markdown);
    try std.testing.expectEqualStrings("name", members[3].name);
    try std.testing.expectEqualStrings("char[16]", members[3].type_name);
    try std.testing.expectEqualStrings("Shown in captures,\ncopied by the call.", members[3].doc.markdown);
}

test "enumerators are split at commas and the last one needs none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/** How a face is culled. */
        \\typedef enum cull_mode
        \\{
        \\    CULL_NONE = 0, ///< Draws both faces.
        \\    /** Drops the back face. */
        \\    CULL_BACK = 1,
        \\    CULL_FRONT ///< Drops the front face.
        \\} cull_mode;
    );
    try std.testing.expectEqual(model.Kind.@"enum", file.decls[0].kind);
    const members = file.decls[0].members;
    try std.testing.expectEqual(3, members.len);
    try std.testing.expectEqual(model.Kind.enumerator, members[0].kind);
    try std.testing.expectEqualStrings("CULL_NONE", members[0].name);
    try std.testing.expectEqualStrings("0", members[0].value);
    try std.testing.expectEqualStrings("Drops the back face.", members[1].doc.markdown);
    try std.testing.expectEqualStrings("sample.h#cull_mode.CULL_FRONT", members[2].id);
    try std.testing.expectEqualStrings("Drops the front face.", members[2].doc.markdown);
}

test "an extern block is transparent, and includes and macros are recorded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(), byte_order_mark ++
        \\#ifndef GUARD_H_
        \\#define GUARD_H_
        \\#include <pool/error.h>
        \\#include "local.h"
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
    try std.testing.expectEqual(2, file.imports.len);
    try std.testing.expectEqualStrings("pool/error.h", file.imports[0].name);
    try std.testing.expectEqualStrings("local.h", file.imports[1].name);
    try std.testing.expectEqual(3, file.decls.len);
    try std.testing.expectEqualStrings("GUARD_H_", file.decls[0].name);
    try std.testing.expectEqual(model.Kind.macro, file.decls[1].kind);
    try std.testing.expectEqualStrings("#define ANSWER 42", file.decls[1].signature);
    try std.testing.expectEqualStrings("The answer.", file.decls[1].doc.markdown);
    try std.testing.expectEqualStrings("stop", file.decls[2].name);
}

test "a file comment documents the file and a note becomes a labelled paragraph" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/**
        \\ * @file sample.h
        \\ * Contracts of the pool.
        \\ */
        \\/**
        \\ * Waits for a task.
        \\ * @note Blocks the caller.
        \\ * @param timeout Unused.
        \\ */
        \\bool wait(task *t);
    );
    try std.testing.expectEqualStrings("Contracts of the pool.", file.doc.markdown);
    const wait = file.decls[0];
    try std.testing.expectEqualStrings("Waits for a task.\n\n**Note:** Blocks the caller.", wait.doc.markdown);
    try std.testing.expectEqual(2, wait.params.len);
    try std.testing.expectEqualStrings("task *", wait.params[0].type_name);
    try std.testing.expectEqualStrings("timeout", wait.params[1].name);
    try std.testing.expectEqualStrings("", wait.params[1].type_name);
}

test "plain comments and banner comments are not documentation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/* plain */
        \\int a;
        \\// plain
        \\int b;
        \\/*** banner ***/
        \\int c;
        \\//// banner
        \\int d;
    );
    try std.testing.expectEqual(4, file.decls.len);
    for (file.decls) |decl| {
        try std.testing.expectEqual(model.Kind.variable, decl.kind);
        try std.testing.expectEqualStrings("", decl.doc.markdown);
    }
}

test "an inline function body is skipped and the next declaration is still read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/** Squares a number. */
        \\static inline int square(int x) { struct { int y; } s; s.y = x; return s.y * x; }
        \\/** Field count. */
        \\int count[4];
    );
    try std.testing.expectEqual(2, file.decls.len);
    try std.testing.expectEqualStrings("square", file.decls[0].name);
    try std.testing.expectEqual(model.Kind.function, file.decls[0].kind);
    try std.testing.expectEqualStrings("x", file.decls[0].params[0].name);
    try std.testing.expectEqualStrings("count", file.decls[1].name);
}
