//! Turns the names a document mentions into references to its declarations.
//!
//! Two things are resolved. The first is a citation: a code span, text between single
//! backticks, that has the shape of a name, which is one identifier or several joined by
//! dots, optionally followed by `()`. Anything else in backticks, such as an expression, a
//! command line or an operator, is not a citation. The second is the target of an `import`
//! or of an `alias` declaration.
//!
//! The first part of a name is looked for in the scopes around the text, innermost first:
//! the members of the declaration being documented, its siblings, and outwards to the top
//! of its file. When no scope has it, every declaration of every file is searched, the
//! file of the text first. Each following part is looked for among the members of what the
//! previous part named, going through an import into the file it resolved to and through
//! an alias into what it names. An import may lead to a file that is not among the ones
//! being resolved, in which case a `Source` is asked for it.
//!
//! A citation that resolves becomes a `model.Link`. A plain name that resolves to nothing
//! is still accepted when it appears in the signature of the declaration being documented,
//! which is how a parameter is cited, or when it is a word of the language. A dotted name is
//! accepted when its first part is unknown, since it is then a file name or a name from
//! outside the sources, and when a part names something whose members are not known, such
//! as an import that was not followed. Every other citation is a `Problem`, and so is a
//! documented parameter that the signature does not have. Problems are only raised for
//! documented files.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

/// One citation that names nothing.
pub const Problem = struct {
    path: []const u8,
    owner: []const u8,
    citation: []const u8,
    kind: Kind,

    pub const Kind = enum { symbol, parameter };
};

/// The files with their links and targets filled in, and what could not be resolved.
pub const Result = struct {
    files: []const model.File,
    problems: []const Problem,
};

/// Supplies a file that an import leads to and that is not among the files being resolved.
pub const Source = struct {
    context: *anyopaque,
    /// The file at `path`, or null when there is none.
    find: *const fn (context: *anyopaque, path: []const u8) Allocator.Error!?*const model.File,
};

/// Resolves the citations and the import and alias targets of `files` against each other.
/// A name that leads through an import to a file outside `files` is followed into what
/// `source` supplies for it.
pub fn resolve(arena: Allocator, files: []const model.File, source: ?Source) Allocator.Error!Result {
    var resolver: Resolver = .{ .arena = arena, .files = files, .source = source };
    const out = try arena.alloc(model.File, files.len);
    for (out, files) |*resolved, *file| {
        resolver.file = file;
        resolver.scopes.clearRetainingCapacity();
        try resolver.scopes.append(arena, file.decls);
        resolved.* = file.*;
        resolved.doc = try resolver.text(file.doc, "the file", "");
        resolved.decls = try resolver.decls(file.decls);
    }
    return .{ .files = out, .problems = try resolver.problems.toOwnedSlice(arena) };
}

const max_indirections = 8;

const c_words = std.StaticStringMap(void).initComptime(.{
    .{"NULL"},     .{"true"},    .{"false"},    .{"void"},     .{"bool"},      .{"char"},
    .{"short"},    .{"int"},     .{"long"},     .{"float"},    .{"double"},    .{"signed"},
    .{"unsigned"}, .{"size_t"},  .{"intptr_t"}, .{"int8_t"},   .{"uintptr_t"}, .{"int16_t"},
    .{"int32_t"},  .{"int64_t"}, .{"uint8_t"},  .{"uint16_t"}, .{"uint32_t"},  .{"uint64_t"},
    .{"struct"},   .{"union"},   .{"enum"},     .{"typedef"},  .{"const"},     .{"static"},
    .{"extern"},   .{"inline"},  .{"volatile"}, .{"restrict"}, .{"sizeof"},    .{"return"},
    .{"if"},       .{"else"},    .{"for"},      .{"while"},    .{"do"},        .{"switch"},
    .{"case"},     .{"default"}, .{"break"},    .{"continue"}, .{"goto"},
});

const Found = struct {
    file: *const model.File,
    decl: ?*const model.Decl,

    fn members(found: Found) []const model.Decl {
        return if (found.decl) |decl| decl.members else found.file.decls;
    }
};

const Outcome = union(enum) {
    linked: []const u8,
    accepted,
    unknown,
};

const Resolver = struct {
    arena: Allocator,
    files: []const model.File,
    source: ?Source,
    file: *const model.File = undefined,
    scopes: std.ArrayList([]const model.Decl) = .empty,
    problems: std.ArrayList(Problem) = .empty,

    fn decls(self: *Resolver, list: []const model.Decl) Allocator.Error![]const model.Decl {
        const out = try self.arena.alloc(model.Decl, list.len);
        for (out, list) |*resolved, *decl| {
            const owner = model.qualifiedName(decl.id);
            resolved.* = decl.*;
            switch (decl.kind) {
                .import => resolved.target = importPath(self.file, decl.value) orelse "",
                .alias => if (try self.expression(self.file, decl.value, max_indirections)) |found| {
                    resolved.target = if (found.decl) |target| target.id else found.file.path;
                },
                else => {},
            }

            try self.scopes.append(self.arena, decl.members);
            resolved.doc = try self.text(decl.doc, owner, decl.signature);
            resolved.returns = try self.text(decl.returns, owner, decl.signature);
            const params = try self.arena.dupe(model.Param, decl.params);
            for (params) |*param| {
                param.doc = try self.text(param.doc, owner, decl.signature);
                if (param.type_name.len == 0 and self.file.language == .c and decl.kind != .macro and isName(param.name)) {
                    try self.report(owner, param.name, .parameter);
                }
            }
            resolved.params = params;
            resolved.members = try self.decls(decl.members);
            _ = self.scopes.pop();
        }
        return out;
    }

    fn report(self: *Resolver, owner: []const u8, citation: []const u8, kind: Problem.Kind) Allocator.Error!void {
        if (!self.file.documented) return;
        try self.problems.append(self.arena, .{ .path = self.file.path, .owner = owner, .citation = citation, .kind = kind });
    }

    fn text(self: *Resolver, source: model.Text, owner: []const u8, signature: []const u8) Allocator.Error!model.Text {
        var links: std.ArrayList(model.Link) = .empty;
        var spans: CodeSpans = .{ .text = source.markdown };
        next: while (spans.next()) |span| {
            const citation = span.content;
            if (!isName(citation)) continue;
            for (links.items) |link| {
                if (std.mem.eql(u8, link.citation, citation)) continue :next;
            }
            switch (try self.cite(citation, signature)) {
                .linked => |target| try links.append(self.arena, .{ .citation = citation, .target = target }),
                .accepted => {},
                .unknown => try self.report(owner, citation, .symbol),
            }
        }
        return .{ .markdown = source.markdown, .links = try links.toOwnedSlice(self.arena) };
    }

    fn cite(self: *Resolver, citation: []const u8, signature: []const u8) Allocator.Error!Outcome {
        const name = if (std.mem.endsWith(u8, citation, "()")) citation[0 .. citation.len - 2] else citation;
        var parts = std.mem.splitScalar(u8, name, '.');
        const first = parts.first();
        const dotted = first.len != name.len;
        var current = self.inScope(first) orelse self.anywhere(first) orelse {
            if (dotted or hasIdentifier(signature, name) or self.isLanguageWord(name)) return .accepted;
            return .unknown;
        };
        while (parts.next()) |part| {
            current = try self.through(current, max_indirections);
            const members = current.members();
            const member = named(members, part) orelse return if (members.len == 0) .accepted else .unknown;
            current = .{ .file = current.file, .decl = member };
        }
        return if (current.decl) |decl| .{ .linked = decl.id } else .accepted;
    }

    fn inScope(self: *Resolver, name: []const u8) ?Found {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (named(self.scopes.items[index], name)) |decl| return .{ .file = self.file, .decl = decl };
        }
        return null;
    }

    fn anywhere(self: *Resolver, name: []const u8) ?Found {
        if (nested(self.file.decls, name)) |decl| return .{ .file = self.file, .decl = decl };
        for (self.files) |*file| {
            if (file == self.file) continue;
            if (nested(file.decls, name)) |decl| return .{ .file = file, .decl = decl };
        }
        return null;
    }

    fn through(self: *Resolver, found: Found, budget: usize) Allocator.Error!Found {
        const decl = found.decl orelse return found;
        if (budget == 0) return found;
        switch (decl.kind) {
            .import => {
                const path = importPath(found.file, decl.value) orelse return found;
                const file = try self.fileAt(path) orelse return found;
                return .{ .file = file, .decl = null };
            },
            .alias => {
                const target = try self.expression(found.file, decl.value, budget - 1) orelse return found;
                return self.through(target, budget - 1);
            },
            else => return found,
        }
    }

    fn expression(self: *Resolver, file: *const model.File, source: []const u8, budget: usize) Allocator.Error!?Found {
        var rest = source;
        var current: Found = undefined;
        const open = "@import(\"";
        if (std.mem.startsWith(u8, rest, open)) {
            const close = std.mem.indexOf(u8, rest, "\")") orelse return null;
            const imported = try self.fileAt(importPath(file, rest[open.len..close]) orelse return null) orelse return null;
            current = .{ .file = imported, .decl = null };
            rest = std.mem.trimStart(u8, rest[close + 2 ..], ".");
            if (rest.len == 0) return current;
        } else {
            const first_end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
            current = .{ .file = file, .decl = named(file.decls, rest[0..first_end]) orelse return null };
            if (first_end == rest.len) return current;
            rest = rest[first_end + 1 ..];
        }
        var parts = std.mem.splitScalar(u8, rest, '.');
        while (parts.next()) |part| {
            current = try self.through(current, budget);
            current = .{ .file = current.file, .decl = named(current.members(), part) orelse return null };
        }
        return current;
    }

    fn fileAt(self: *Resolver, path: []const u8) Allocator.Error!?*const model.File {
        for (self.files) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        const source = self.source orelse return null;
        return source.find(source.context, path);
    }

    fn isLanguageWord(self: *Resolver, name: []const u8) bool {
        return switch (self.file.language) {
            .zig => std.zig.Token.getKeyword(name) != null or std.zig.primitives.isPrimitive(name),
            .c => c_words.has(name),
        };
    }
};

fn importPath(file: *const model.File, name: []const u8) ?[]const u8 {
    for (file.imports) |import| {
        if (import.path.len != 0 and std.mem.eql(u8, import.name, name)) return import.path;
    }
    return null;
}

fn named(list: []const model.Decl, name: []const u8) ?*const model.Decl {
    for (list) |*decl| {
        if (std.mem.eql(u8, decl.name, name)) return decl;
    }
    return null;
}

fn nested(list: []const model.Decl, name: []const u8) ?*const model.Decl {
    if (named(list, name)) |decl| return decl;
    for (list) |*decl| {
        if (nested(decl.members, name)) |found| return found;
    }
    return null;
}

/// Iterates the code spans of Markdown text that sit on one line and outside a fenced block.
pub const CodeSpans = struct {
    text: []const u8,
    at: usize = 0,
    fenced: bool = false,

    pub const Span = struct {
        /// Offset of the opening backtick.
        start: usize,
        /// Offset just past the closing backtick.
        end: usize,
        content: []const u8,
    };

    /// The next span delimited by single backticks, or null at the end of the text.
    pub fn next(spans: *CodeSpans) ?Span {
        const text = spans.text;
        while (spans.at < text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, spans.at, '\n') orelse text.len;
            const at_line_start = spans.at == 0 or text[spans.at - 1] == '\n';
            if (at_line_start and std.mem.startsWith(u8, std.mem.trimStart(u8, text[spans.at..line_end], " \t"), "```")) {
                spans.fenced = !spans.fenced;
                spans.at = @min(line_end + 1, text.len);
                continue;
            }
            if (spans.fenced) {
                spans.at = @min(line_end + 1, text.len);
                continue;
            }
            const open = std.mem.indexOfScalarPos(u8, text[0..line_end], spans.at, '`') orelse {
                spans.at = @min(line_end + 1, text.len);
                continue;
            };
            var ticks: usize = 1;
            while (open + ticks < line_end and text[open + ticks] == '`') ticks += 1;
            const start = open + ticks;
            const close = std.mem.indexOfPos(u8, text[0..line_end], start, text[open..start]) orelse {
                spans.at = @min(line_end + 1, text.len);
                continue;
            };
            spans.at = close + ticks;
            if (ticks == 1) return .{ .start = open, .end = close + 1, .content = text[start..close] };
        }
        return null;
    }
};

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isName(span: []const u8) bool {
    const name = if (std.mem.endsWith(u8, span, "()")) span[0 .. span.len - 2] else span;
    if (name.len == 0) return false;
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or std.ascii.isDigit(part[0])) return false;
        for (part) |ch| {
            if (!isIdentifierChar(ch)) return false;
        }
    }
    return true;
}

fn hasIdentifier(haystack: []const u8, name: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, name)) |found| {
        const stop = found + name.len;
        const starts = found == 0 or !isIdentifierChar(haystack[found - 1]);
        const stops = stop == haystack.len or !isIdentifierChar(haystack[stop]);
        if (starts and stops) return true;
        at = found + 1;
    }
    return false;
}

const zig_source = @import("zig_source.zig");
const doxygen = @import("doxygen.zig");

fn resolveZig(arena: Allocator, source: [:0]const u8) !Result {
    return resolve(arena, &.{try zig_source.read(arena, "a.zig", source)}, null);
}

fn linkOf(text: model.Text, citation: []const u8) ?[]const u8 {
    for (text.links) |link| {
        if (std.mem.eql(u8, link.citation, citation)) return link.target;
    }
    return null;
}

test "a citation links to the declaration it names, by plain or qualified name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try resolveZig(arena.allocator(),
        \\//! See `Task`, `run`, `Task.run` and `wait()`.
        \\const Task = struct {
        \\    fn run() void {}
        \\};
        \\fn wait() void {}
    );
    try std.testing.expectEqual(0, result.problems.len);
    const doc = result.files[0].doc;
    try std.testing.expectEqualStrings("a.zig#Task", linkOf(doc, "Task").?);
    try std.testing.expectEqualStrings("a.zig#Task.run", linkOf(doc, "run").?);
    try std.testing.expectEqualStrings("a.zig#Task.run", linkOf(doc, "Task.run").?);
    try std.testing.expectEqualStrings("a.zig#wait", linkOf(doc, "wait()").?);
}

test "the nearest scope wins when a name is declared twice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try resolveZig(arena.allocator(),
        \\fn run() void {}
        \\const Task = struct {
        \\    /// Calls `run`.
        \\    fn start() void {}
        \\    fn run() void {}
        \\};
    );
    const start = result.files[0].decls[1].members[0];
    try std.testing.expectEqualStrings("a.zig#Task.run", linkOf(start.doc, "run").?);
}

test "a citation that names nothing is reported with the declaration that cites it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try resolveZig(arena.allocator(),
        \\const Task = struct {
        \\    /// Calls `finish` and `Task.stop`.
        \\    fn run() void {}
        \\};
    );
    try std.testing.expectEqual(2, result.problems.len);
    try std.testing.expectEqualStrings("finish", result.problems[0].citation);
    try std.testing.expectEqualStrings("Task.run", result.problems[0].owner);
    try std.testing.expectEqualStrings("Task.stop", result.problems[1].citation);
}

test "a parameter and a word of the language are accepted without a link" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try resolveZig(arena.allocator(),
        \\/// Adds `left` to `right` as `u32`, never `null`, in a `test`.
        \\fn add(left: u32, right: u32) u32 {
        \\    return left + right;
        \\}
    );
    try std.testing.expectEqual(0, result.problems.len);
    try std.testing.expectEqual(0, result.files[0].decls[0].doc.links.len);
}

test "a code span that is not a name is not a citation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try resolveZig(arena.allocator(),
        \\//! Run `zig build`, write `a + b`, open `//!`, pass `--out`.
        \\//! ``missing``
        \\//! ```
        \\//! `missing`
        \\//! ```
    );
    try std.testing.expectEqual(0, result.problems.len);
}

test "a dotted name is accepted when its first part is unknown or was not followed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try resolveZig(arena.allocator(),
        \\//! See `build.zig`, `error.OutOfMemory` and `std.mem.Allocator`.
        \\const std = @import("std");
    );
    try std.testing.expectEqual(0, result.problems.len);
    try std.testing.expectEqual(0, result.files[0].doc.links.len);
}

test "an import and an alias lead to the declaration in the other file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var main = try zig_source.read(allocator, "main.zig",
        \\//! Uses `model.Entry.name`, `Entry` and `Name`.
        \\const model = @import("model.zig");
        \\const Entry = model.Entry;
        \\const Name = @import("model.zig").Entry.name;
    );
    main.imports = &.{.{ .name = "model.zig", .kind = .file, .path = "model.zig" }};
    const other = try zig_source.read(allocator, "model.zig",
        \\pub const Entry = struct {
        \\    name: []const u8,
        \\};
    );
    const result = try resolve(allocator, &.{ other, main }, null);
    try std.testing.expectEqual(0, result.problems.len);
    const resolved = result.files[1];
    try std.testing.expectEqualStrings("model.zig#Entry.name", linkOf(resolved.doc, "model.Entry.name").?);
    try std.testing.expectEqualStrings("model.zig", resolved.decls[0].target);
    try std.testing.expectEqualStrings("model.zig#Entry", resolved.decls[1].target);
    try std.testing.expectEqualStrings("model.zig#Entry.name", resolved.decls[2].target);
}

test "a name declared in another file is found, and a problem in an undocumented file is not raised" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const zig = try zig_source.read(allocator, "a.zig", "//! Fills a `ke_error` through `ke_pool.wait`.\n");
    var header = try doxygen.read(allocator, "pool.h",
        \\/** Cites `nothing_declared`. */
        \\typedef struct ke_error ke_error;
        \\typedef struct ke_pool { bool (*wait)(void); } ke_pool;
    );
    header.documented = false;
    const result = try resolve(allocator, &.{ header, zig }, null);
    try std.testing.expectEqual(0, result.problems.len);
    try std.testing.expectEqualStrings("pool.h#ke_error", linkOf(result.files[1].doc, "ke_error").?);
    try std.testing.expectEqualStrings("pool.h#ke_pool.wait", linkOf(result.files[1].doc, "ke_pool.wait").?);
}

test "a documented parameter that the signature does not have is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const header = try doxygen.read(allocator, "a.h",
        \\/**
        \\ * @param t The task, never `NULL`.
        \\ * @param timeout Unused.
        \\ */
        \\bool wait(task *t);
    );
    const result = try resolve(allocator, &.{header}, null);
    try std.testing.expectEqual(1, result.problems.len);
    try std.testing.expectEqualStrings("timeout", result.problems[0].citation);
    try std.testing.expectEqual(Problem.Kind.parameter, result.problems[0].kind);
}

const Shelf = struct {
    file: model.File,
    asked: usize = 0,

    fn find(context: *anyopaque, path: []const u8) Allocator.Error!?*const model.File {
        const shelf: *Shelf = @ptrCast(@alignCast(context));
        shelf.asked += 1;
        return if (std.mem.eql(u8, path, shelf.file.path)) &shelf.file else null;
    }
};

test "a name that leads outside the files is followed into what the source supplies" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var main = try zig_source.read(allocator, "main.zig",
        \\//! Takes a `lib.Buffer`, never a `lib.Missing`. See `Buffer`.
        \\const lib = @import("lib");
        \\const Buffer = lib.Buffer;
    );
    main.imports = &.{.{ .name = "lib", .kind = .module, .path = "lib/lib.zig" }};
    var shelf: Shelf = .{ .file = try zig_source.read(allocator, "lib/lib.zig", "pub const Buffer = struct {};\n") };
    const result = try resolve(allocator, &.{main}, .{ .context = &shelf, .find = Shelf.find });

    try std.testing.expectEqual(1, result.problems.len);
    try std.testing.expectEqualStrings("lib.Missing", result.problems[0].citation);
    try std.testing.expectEqualStrings("lib/lib.zig#Buffer", linkOf(result.files[0].doc, "lib.Buffer").?);
    try std.testing.expectEqualStrings("lib/lib.zig#Buffer", result.files[0].decls[1].target);
    try std.testing.expect(shelf.asked != 0);
}
