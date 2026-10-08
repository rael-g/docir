//! Checks that what the documentation cites exists in the code.
//!
//! A citation is a code span, text between single backticks, that has the shape of a name:
//! one identifier, or several joined by dots, optionally followed by `()`. Anything else in
//! backticks, such as an expression, a command line or an operator, is not a citation.
//!
//! A plain name resolves when it is a declared symbol, when it is the last part of a
//! qualified one, when it appears in the signature of the declaration being documented
//! (which is how a parameter is cited), or when it is a word of the language.
//!
//! A dotted name is judged by its first part. When that part is not a known symbol the
//! citation is taken for something else, a file name or a name from outside the sources,
//! and is let through. When it is a symbol whose members are known, the whole name has to
//! resolve. When it is a symbol with no known members, an import for instance, it is let
//! through.
//!
//! A parameter documented by name has to appear in the signature it documents.

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

/// Returns every citation in `units` that resolves neither against the symbols of `units`
/// nor against those of `extra`, whose documentation is not itself checked.
pub fn check(arena: Allocator, units: []const model.Unit, extra: []const model.Unit) Allocator.Error![]const Problem {
    var symbols: std.ArrayList([]const u8) = .empty;
    for (units) |unit| try symbols.appendSlice(arena, unit.symbols);
    for (extra) |unit| try symbols.appendSlice(arena, unit.symbols);

    var checker: Checker = .{ .arena = arena, .symbols = symbols.items };
    for (units) |unit| {
        checker.path = unit.path;
        checker.language = unit.language;
        try checker.text(unit.intro, "the file", "");
        try checker.entries(unit.entries, "");
    }
    return checker.problems.toOwnedSlice(arena);
}

const c_words = [_][]const u8{
    "NULL",     "true",     "false",   "void",    "bool",     "char",     "short",    "int",
    "long",     "float",    "double",  "signed",  "unsigned", "size_t",   "intptr_t", "uintptr_t",
    "int8_t",   "int16_t",  "int32_t", "int64_t", "uint8_t",  "uint16_t", "uint32_t", "uint64_t",
    "struct",   "union",    "enum",    "typedef", "const",    "static",   "extern",   "inline",
    "volatile", "restrict", "sizeof",  "return",  "if",       "else",     "for",      "while",
    "do",       "switch",   "case",    "default", "break",    "continue", "goto",
};

const Checker = struct {
    arena: Allocator,
    symbols: []const []const u8,
    path: []const u8 = "",
    language: []const u8 = "",
    problems: std.ArrayList(Problem) = .empty,

    fn entries(self: *Checker, list: []const model.Entry, parent: []const u8) Allocator.Error!void {
        for (list) |entry| {
            const owner = if (parent.len == 0) entry.name else try std.mem.concat(self.arena, u8, &.{ parent, ".", entry.name });
            try self.text(entry.text, owner, entry.signature);
            try self.text(entry.returns, owner, entry.signature);
            for (entry.params) |param| {
                if (isName(param.name) and !hasIdentifier(entry.signature, param.name)) {
                    try self.problems.append(self.arena, .{ .path = self.path, .owner = owner, .citation = param.name, .kind = .parameter });
                }
                try self.text(param.text, owner, entry.signature);
            }
            try self.entries(entry.members, owner);
        }
    }

    fn text(self: *Checker, content: []const u8, owner: []const u8, signature: []const u8) Allocator.Error!void {
        var fenced = false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
                fenced = !fenced;
                continue;
            }
            if (fenced) continue;
            var at: usize = 0;
            while (std.mem.indexOfScalarPos(u8, line, at, '`')) |open| {
                var ticks: usize = 1;
                while (open + ticks < line.len and line[open + ticks] == '`') ticks += 1;
                const start = open + ticks;
                const close = std.mem.indexOfPos(u8, line, start, line[open..start]) orelse break;
                at = close + ticks;
                if (ticks != 1) continue;
                const citation = line[start..close];
                if (!isName(citation) or self.resolves(citation, signature)) continue;
                try self.problems.append(self.arena, .{ .path = self.path, .owner = owner, .citation = citation, .kind = .symbol });
            }
        }
    }

    fn resolves(self: *Checker, citation: []const u8, signature: []const u8) bool {
        const name = if (std.mem.endsWith(u8, citation, "()")) citation[0 .. citation.len - 2] else citation;
        if (self.declared(name)) return true;
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse
            return hasIdentifier(signature, name) or self.isLanguageWord(name);
        const root = self.qualifiedNameOf(name[0..dot]) orelse return true;
        return !self.hasMembers(root);
    }

    fn declared(self: *Checker, name: []const u8) bool {
        return self.qualifiedNameOf(name) != null;
    }

    fn qualifiedNameOf(self: *Checker, name: []const u8) ?[]const u8 {
        for (self.symbols) |symbol| {
            if (std.mem.eql(u8, symbol, name)) return symbol;
            if (symbol.len > name.len and std.mem.endsWith(u8, symbol, name) and symbol[symbol.len - name.len - 1] == '.') return symbol;
        }
        return null;
    }

    fn hasMembers(self: *Checker, qualified: []const u8) bool {
        for (self.symbols) |symbol| {
            if (symbol.len > qualified.len and std.mem.startsWith(u8, symbol, qualified) and symbol[qualified.len] == '.') return true;
        }
        return false;
    }

    fn isLanguageWord(self: *Checker, name: []const u8) bool {
        if (std.mem.eql(u8, self.language, "zig")) {
            return std.zig.Token.getKeyword(name) != null or std.zig.primitives.isPrimitive(name);
        }
        for (c_words) |word| {
            if (std.mem.eql(u8, word, name)) return true;
        }
        return false;
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

fn problemsOf(arena: Allocator, unit: model.Unit) ![]const Problem {
    return check(arena, &.{unit}, &.{});
}

test "a cited symbol resolves by its name, by its qualified name and with call parentheses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const problems = try problemsOf(arena.allocator(), .{
        .path = "a.zig",
        .language = "zig",
        .intro = "See `Task`, `run`, `Task.run` and `wait()`.",
        .symbols = &.{ "Task", "Task.run", "wait" },
    });
    try std.testing.expectEqual(0, problems.len);
}

test "a citation that names nothing is reported with the declaration that cites it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const problems = try problemsOf(arena.allocator(), .{
        .path = "a.zig",
        .language = "zig",
        .entries = &.{.{
            .name = "Task",
            .signature = "const Task = struct",
            .members = &.{.{ .name = "run", .signature = "fn run() void", .text = "Calls `finish` and `Task.stop`." }},
        }},
        .symbols = &.{ "Task", "Task.run" },
    });
    try std.testing.expectEqual(2, problems.len);
    try std.testing.expectEqualStrings("finish", problems[0].citation);
    try std.testing.expectEqualStrings("Task.run", problems[0].owner);
    try std.testing.expectEqualStrings("Task.stop", problems[1].citation);
}

test "a parameter and a word of the language are citable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const problems = try problemsOf(arena.allocator(), .{
        .path = "a.zig",
        .language = "zig",
        .entries = &.{.{ .name = "add", .signature = "fn add(left: u32, right: u32) u32", .text = "Adds `left` to `right` as `u32`, never `null`, in a `test`." }},
        .symbols = &.{"add"},
    });
    try std.testing.expectEqual(0, problems.len);
}

test "a code span that is not a name is not a citation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const problems = try problemsOf(arena.allocator(), .{
        .path = "a.zig",
        .language = "zig",
        .intro = "Run `zig build`, write `a + b`, open `//!`, pass `--out`.\n``missing``\n```\n`missing`\n```",
    });
    try std.testing.expectEqual(0, problems.len);
}

test "a dotted name is let through when its first part is unknown or has no known members" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const problems = try problemsOf(arena.allocator(), .{
        .path = "a.zig",
        .language = "zig",
        .intro = "See `build.zig`, `error.OutOfMemory` and `std.mem.Allocator`.",
        .symbols = &.{"std"},
    });
    try std.testing.expectEqual(0, problems.len);
}

test "a symbol of an extra unit resolves a citation without that unit being checked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const problems = try check(arena.allocator(), &.{.{
        .path = "a.zig",
        .language = "zig",
        .intro = "Fills a `ke_error`.",
    }}, &.{.{
        .path = "error.h",
        .language = "c",
        .intro = "Cites `nothing_declared`.",
        .symbols = &.{"ke_error"},
    }});
    try std.testing.expectEqual(0, problems.len);
}

test "a documented parameter that the signature does not have is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const problems = try problemsOf(arena.allocator(), .{
        .path = "a.h",
        .language = "c",
        .entries = &.{.{
            .name = "wait",
            .signature = "bool wait(task *t)",
            .params = &.{ .{ .name = "t", .text = "The task, never `NULL`." }, .{ .name = "timeout", .text = "Unused." } },
        }},
        .symbols = &.{"wait"},
    });
    try std.testing.expectEqual(1, problems.len);
    try std.testing.expectEqualStrings("timeout", problems[0].citation);
    try std.testing.expectEqual(Problem.Kind.parameter, problems[0].kind);
}
