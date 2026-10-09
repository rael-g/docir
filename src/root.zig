//! docir turns the documentation written in source code into data, and that data into text.
//!
//! The work is done in three stages around one representation, `ir`. A reader turns the
//! sources of one language into it: `zig_source` reads Zig, `c_source` reads C and C++ and
//! `csharp_source` reads C#, and `project` decides which files they read, by following
//! imports from the root file of a module or by taking every file of a directory. `link` resolves the names the documentation mentions into references. A writer
//! renders the result: `markdown` writes one Markdown file and `text` writes for a terminal,
//! where `query` finds the symbols a name asks for. Between stages the representation is
//! JSON, written by `ir.writeJson` and read back by `ir.readJson`, so a stage may as well
//! be another program, and `schema` describes that JSON to one.
//!
//! `read`, `combine` and `resolve` are the first two stages as functions. `cli` offers the
//! three stages as the commands of the program, and the build file of this package runs
//! that program as the steps of a build, with what `read` needs taken from a module.

const std = @import("std");

pub const ir = @import("ir.zig");
pub const project = @import("project.zig");
pub const link = @import("link.zig");
pub const schema = @import("schema.zig");
pub const markdown = @import("markdown.zig");
pub const text = @import("text.zig");
pub const query = @import("query.zig");
pub const markdown_text = @import("markdown_text.zig");
pub const zig_source = @import("zig_source.zig");
pub const c_source = @import("c_source.zig");
pub const csharp_source = @import("csharp_source.zig");
pub const xml_comment = @import("xml_comment.zig");
pub const doxygen_comment = @import("doxygen_comment.zig");
pub const cli = @import("cli.zig");

/// Reads the root of `options` and everything it imports into a document that is not
/// linked. An import into a reference-only module keeps the path of the file it leads to,
/// and that file is not in the document.
pub fn read(arena: std.mem.Allocator, io: std.Io, options: project.Options) !ir.Document {
    return documentOf(arena, try project.Project.open(arena, io, options));
}

/// The document of what `loaded` read, not linked. Its files are in the order of their
/// paths, so the same sources always give the same document, whatever order they were
/// reached in and whether they were read from a root file or from a directory.
pub fn documentOf(arena: std.mem.Allocator, loaded: project.Project) std.mem.Allocator.Error!ir.Document {
    const units = try arena.dupe(ir.Unit, loaded.units.items);
    std.mem.sort(ir.Unit, units, {}, struct {
        fn before(_: void, a: ir.Unit, b: ir.Unit) bool {
            return std.mem.lessThan(u8, a.file.path, b.file.path);
        }
    }.before);
    const files = try arena.alloc(ir.File, units.len);
    const symbols = try arena.alloc(ir.Symbol, units.len);
    for (files, symbols, units) |*file, *symbol, unit| {
        file.* = unit.file;
        symbol.* = unit.symbol;
    }
    return .{ .files = files, .symbols = symbols };
}

/// `document` with its files rearranged for a writer: those under the first of `prefixes`
/// come first, then those under the second, and so on, and a file under none of them comes
/// after all of those. A prefix is a directory or a whole file path, as the document names
/// it. Within one group the files keep the order they had.
pub fn ordered(arena: std.mem.Allocator, document: ir.Document, prefixes: []const []const u8) std.mem.Allocator.Error!ir.Document {
    if (prefixes.len == 0) return document;
    const Ranking = struct {
        prefixes: []const []const u8,

        fn of(self: @This(), path: []const u8) usize {
            for (self.prefixes, 0..) |prefix, index| {
                const dir = std.mem.trimEnd(u8, prefix, "/");
                if (std.mem.eql(u8, path, dir)) return index;
                if (path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/') return index;
            }
            return self.prefixes.len;
        }

        fn fileBefore(self: @This(), a: ir.File, b: ir.File) bool {
            return self.of(a.path) < self.of(b.path);
        }

        fn symbolBefore(self: @This(), a: ir.Symbol, b: ir.Symbol) bool {
            return self.of(pathOf(a)) < self.of(pathOf(b));
        }

        fn pathOf(symbol: ir.Symbol) []const u8 {
            return if (symbol.locations.len == 0) "" else symbol.locations[0].file;
        }
    };
    const ranking: Ranking = .{ .prefixes = prefixes };
    const files = try arena.dupe(ir.File, document.files);
    const symbols = try arena.dupe(ir.Symbol, document.symbols);
    std.mem.sort(ir.File, files, ranking, Ranking.fileBefore);
    std.mem.sort(ir.Symbol, symbols, ranking, Ranking.symbolBefore);
    var result = document;
    result.files = files;
    result.symbols = symbols;
    return result;
}

/// The files of every one of `documents` in one document that is not linked. A file that
/// several of them hold is taken from the first, except that it is documented when any of
/// them documents it.
pub fn combine(arena: std.mem.Allocator, documents: []const ir.Document) std.mem.Allocator.Error!ir.Document {
    var files: std.ArrayList(ir.File) = .empty;
    var symbols: std.ArrayList(ir.Symbol) = .empty;
    var positions: std.StringHashMapUnmanaged(usize) = .empty;
    for (documents) |document| {
        const count = @min(document.files.len, document.symbols.len);
        for (document.files[0..count], document.symbols[0..count]) |file, symbol| {
            const entry = try positions.getOrPut(arena, file.path);
            if (entry.found_existing) {
                if (file.documented) files.items[entry.value_ptr.*].documented = true;
                continue;
            }
            entry.value_ptr.* = files.items.len;
            try files.append(arena, file);
            try symbols.append(arena, symbol);
        }
    }
    return .{ .files = try files.toOwnedSlice(arena), .symbols = try symbols.toOwnedSlice(arena) };
}

/// Links `document`. A reference that goes through an import into one of `references` is
/// followed into the sources of that module, which are read from disk as they are reached.
/// What was reached comes first in the linked document and holds only the symbols that a
/// reference names or reaches into. A mention of one of `external` is no problem.
pub fn resolve(arena: std.mem.Allocator, io: std.Io, document: ir.Document, references: []const project.Module, external: []const []const u8) std.mem.Allocator.Error!link.Result {
    if (references.len == 0) return link.link(arena, document, .{ .external = external });
    var loaded = try project.Project.references(arena, io, references);
    return link.link(arena, document, .{ .source = .{ .context = &loaded, .find = find }, .external = external });
}

/// One line saying what `problem` is, for the person who wrote the documentation.
pub fn describe(arena: std.mem.Allocator, problem: link.Problem) std.mem.Allocator.Error![]const u8 {
    return switch (problem.kind) {
        .symbol => std.fmt.allocPrint(arena, "{s}: `{s}`, cited by {s}, is not declared", .{ problem.path, problem.citation, problem.owner }),
        .parameter => std.fmt.allocPrint(arena, "{s}: {s} documents a parameter `{s}` it does not have", .{ problem.path, problem.owner, problem.citation }),
    };
}

fn find(context: *anyopaque, path: []const u8) std.mem.Allocator.Error!?*const ir.Unit {
    const loaded: *project.Project = @ptrCast(@alignCast(context));
    return loaded.reference(path);
}

test "combined documents hold each file once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const header: ir.Symbol = .{ .id = "c:pool.h", .name = "pool.h", .qualified_name = "pool.h", .kind = .module };
    const first: ir.Document = .{
        .files = &.{ .{ .path = "pool.h", .language = "c", .documented = false }, .{ .path = "a.zig", .language = "zig" } },
        .symbols = &.{ header, .{ .id = "zig:a.zig", .name = "a.zig", .qualified_name = "a.zig", .kind = .module } },
    };
    const second: ir.Document = .{
        .files = &.{.{ .path = "pool.h", .language = "c" }},
        .symbols = &.{header},
    };
    const combined = try combine(arena.allocator(), &.{ first, second });
    try std.testing.expectEqual(2, combined.files.len);
    try std.testing.expectEqual(2, combined.symbols.len);
    try std.testing.expect(combined.files[0].documented);
    try std.testing.expect(!combined.linked);
}

test "the files of a document are in the order of their paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "plugin/src");
    try tmp.dir.createDirPath(std.testing.io, "plugin/include");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plugin/src/main.zig", .data =
        \\const zebra = @import("zebra.zig");
        \\const apple = @import("apple.zig");
        \\const c = @cImport(@cInclude("pool.h"));
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plugin/src/zebra.zig", .data = "const apple = @import(\"apple.zig\");\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plugin/src/apple.zig", .data = "pub fn eat() void {}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plugin/include/pool.h", .data = "void stop(void);\n" });

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const join = std.fs.path.join;
    const document = try read(arena.allocator(), std.testing.io, .{
        .modules = &.{.{
            .name = "plugin",
            .path = try join(arena.allocator(), &.{ base, "plugin/src/main.zig" }),
            .include_dirs = &.{try join(arena.allocator(), &.{ base, "plugin/include" })},
        }},
        .base = try join(arena.allocator(), &.{ base, "plugin" }),
    });

    const expected: []const []const u8 = &.{ "pool.h", "src/apple.zig", "src/main.zig", "src/zebra.zig" };
    try std.testing.expectEqual(expected.len, document.files.len);
    for (expected, document.files, document.symbols) |path, file, symbol| {
        try std.testing.expectEqualStrings(path, file.path);
        try std.testing.expectEqualStrings(path, symbol.locations[0].file);
    }
}

test "a caller's order groups the files by prefix and keeps the rest as it was" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const paths: []const []const u8 = &.{ "contracts/pool.h", "include/create.h", "src/apple.zig", "src/main.zig", "srcs/other.zig" };
    const files = try arena.allocator().alloc(ir.File, paths.len);
    const symbols = try arena.allocator().alloc(ir.Symbol, paths.len);
    for (paths, files, symbols) |path, *file, *symbol| {
        file.* = .{ .path = path, .language = "zig" };
        symbol.* = .{ .id = path, .name = path, .qualified_name = path, .kind = .module, .locations = try arena.allocator().dupe(ir.Location, &.{.{ .file = path, .line = 1 }}) };
    }
    const document: ir.Document = .{ .files = files, .symbols = symbols };

    const result = try ordered(arena.allocator(), document, &.{ "src/main.zig", "src/", "include" });
    const expected: []const []const u8 = &.{ "src/main.zig", "src/apple.zig", "include/create.h", "contracts/pool.h", "srcs/other.zig" };
    for (expected, result.files, result.symbols) |path, file, symbol| {
        try std.testing.expectEqualStrings(path, file.path);
        try std.testing.expectEqualStrings(path, symbol.name);
    }
    try std.testing.expectEqualStrings("contracts/pool.h", (try ordered(arena.allocator(), document, &.{})).files[0].path);
}

test {
    std.testing.refAllDecls(@This());
}
