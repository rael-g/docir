//! The language-neutral shape every reader produces and every writer consumes.
//!
//! A reader turns one source file into a `File`: its documentation, what it imports and
//! every declaration it holds, documented or not. A `Document` is a set of files reached
//! from one root, and it is the form the model takes outside the process: JSON whose fields
//! are the fields declared here, under the same names. Extraction ends in that JSON and a
//! writer starts from it, so a writer never reads a source file.
//!
//! A declaration is identified by the path of its file, a `#`, and its name qualified by
//! the containers around it, as in `src/pool.zig#Pool.wait`. Every reference in the document,
//! a `Link` or a `Decl.target`, is such an identifier, or the path of a file.

const std = @import("std");

/// Version of the JSON layout. A file carrying another one is refused.
pub const format_version = 1;

/// The files reached from one root. The files that are only a target of references come
/// first, cut down to the declarations a reference names; the others follow, dependencies
/// before the files that import them.
pub const Document = struct {
    format: u32 = format_version,
    root: []const u8,
    files: []const File,
};

pub const Language = enum { zig, c };

/// Everything one source file says about itself. A file that is not `documented` was
/// reached through an import and is present only so that references into it resolve.
pub const File = struct {
    path: []const u8,
    language: Language,
    documented: bool = true,
    doc: Text = .{},
    imports: []const Import = &.{},
    decls: []const Decl = &.{},
    behaviours: []const []const u8 = &.{},
};

/// Documentation text in Markdown, with the citations in it that resolved to a declaration.
pub const Text = struct {
    markdown: []const u8 = "",
    links: []const Link = &.{},
};

/// A code span of a `Text` and the identifier of the declaration it names.
pub const Link = struct {
    citation: []const u8,
    target: []const u8,
};

/// Something a file pulls in. `path` is the path of the `File` it resolved to, or empty
/// when it lies outside what was given to the extraction. A path into a module that is
/// only a target of references names a file that is in the document when a reference names
/// a declaration of it.
pub const Import = struct {
    name: []const u8,
    kind: ImportKind,
    path: []const u8 = "",
};

pub const ImportKind = enum { file, module, include };

/// One parameter of a function-like declaration.
pub const Param = struct {
    name: []const u8,
    type_name: []const u8 = "",
    doc: Text = .{},
};

pub const Kind = enum {
    function,
    type_function,
    @"struct",
    @"enum",
    @"union",
    @"opaque",
    error_set,
    error_value,
    constant,
    variable,
    field,
    enumerator,
    import,
    alias,
    typedef,
    macro,
};

/// One declaration. `value` is the initial value of a constant or the default of a field,
/// the imported name of an `import` and the aliased expression of an `alias`. `target` is
/// the path of the file an `import` resolved to, or the identifier of the declaration an
/// `alias` names. An example is source code that uses the declaration, taken from a test.
pub const Decl = struct {
    id: []const u8,
    name: []const u8,
    kind: Kind,
    public: bool = true,
    line: u32 = 0,
    end_line: u32 = 0,
    signature: []const u8 = "",
    doc: Text = .{},
    params: []const Param = &.{},
    return_type: []const u8 = "",
    returns: Text = .{},
    type_name: []const u8 = "",
    value: []const u8 = "",
    target: []const u8 = "",
    examples: []const []const u8 = &.{},
    members: []const Decl = &.{},
};

/// The name of a declaration qualified by its containers, which is its identifier without
/// the path of its file.
pub fn qualifiedName(id: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, id, '#') orelse return id;
    return id[hash + 1 ..];
}

/// Writes `document` as indented JSON.
pub fn writeJson(writer: *std.Io.Writer, document: Document) std.Io.Writer.Error!void {
    try std.json.Stringify.value(document, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

/// Reads a `Document` back. Fails with `error.UnsupportedFormat` when the file was written
/// in another `format_version`, and with the JSON parser's error when it is not a document.
pub fn readJson(arena: std.mem.Allocator, bytes: []const u8) !Document {
    const document = try std.json.parseFromSliceLeaky(Document, arena, bytes, .{});
    if (document.format != format_version) return error.UnsupportedFormat;
    return document;
}

test "a document survives the trip through JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const original: Document = .{ .root = "a.zig", .files = &.{.{
        .path = "a.h",
        .language = .c,
        .documented = false,
        .doc = .{ .markdown = "Line one.\n\"Quoted\" `pool`.", .links = &.{.{ .citation = "pool", .target = "a.h#pool" }} },
        .imports = &.{.{ .name = "b.h", .kind = .include, .path = "b.h" }},
        .decls = &.{.{
            .id = "a.h#pool",
            .name = "pool",
            .kind = .@"struct",
            .line = 3,
            .end_line = 9,
            .signature = "typedef struct pool",
            .members = &.{.{
                .id = "a.h#pool.wait",
                .name = "wait",
                .kind = .field,
                .signature = "bool (*wait)(pool *self)",
                .doc = .{ .markdown = "Waits." },
                .params = &.{.{ .name = "self", .type_name = "pool *", .doc = .{ .markdown = "The pool." } }},
                .return_type = "bool",
                .returns = .{ .markdown = "False on failure." },
                .examples = &.{"try pool.wait();"},
            }},
        }},
        .behaviours = &.{"it waits"},
    }} };

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeJson(&out.writer, original);
    const copy = try readJson(arena.allocator(), out.written());

    try std.testing.expectEqualDeep(original, copy);
}

test "a document written in another format version is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFormat, readJson(arena.allocator(), "{\"format\": 0, \"root\": \"\", \"files\": []}"));
}

test "the qualified name of a declaration is its identifier without the file" {
    try std.testing.expectEqualStrings("Pool.wait", qualifiedName("src/pool.zig#Pool.wait"));
}
