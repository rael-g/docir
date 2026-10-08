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
    /// The `format_version` the document was written in.
    format: u32 = format_version,
    /// Path of the file the extraction started at.
    root: []const u8,
    /// Every file of the document, each under a path no other has.
    files: []const File,
};

/// The language of a source file, which is also the reader that read it.
pub const Language = enum {
    /// Read by `zig_source`.
    zig,
    /// A C header or source file, read by `doxygen`.
    c,
};

/// Everything one source file says about itself. A file that is not `documented` was
/// reached through an import and is present only so that references into it resolve.
pub const File = struct {
    /// Path of the file within the document, with `/` between its parts. It identifies the
    /// file and never names the machine the file was read on.
    path: []const u8,
    /// The language the file is written in.
    language: Language,
    /// Whether the file is part of what is being documented.
    documented: bool = true,
    /// The documentation of the file as a whole: `//!` in Zig, a `@file` block in C.
    doc: Text = .{},
    /// What the file imports or includes, in source order.
    imports: []const Import = &.{},
    /// The top-level declarations of the file, in source order.
    decls: []const Decl = &.{},
    /// The names of the tests of the file that are named by a sentence and not by a
    /// declaration.
    behaviours: []const []const u8 = &.{},
};

/// Documentation text in Markdown, with the citations in it that resolved to a declaration.
pub const Text = struct {
    /// The text as written, without the comment markers. Empty when there is none.
    markdown: []const u8 = "",
    /// One entry per distinct citation of `markdown` that resolved.
    links: []const Link = &.{},
};

/// A code span of a `Text` and the identifier of the declaration it names.
pub const Link = struct {
    /// The content of the code span, exactly as written between the backticks.
    citation: []const u8,
    /// Identifier of the declaration the citation names.
    target: []const u8,
};

/// Something a file pulls in. `path` is the path of the `File` it resolved to, or empty
/// when it lies outside what was given to the extraction. A path into a module that is
/// only a target of references names a file that is in the document when a reference names
/// a declaration of it.
pub const Import = struct {
    /// The name as written in the source: a relative path, a module name or a header name.
    name: []const u8,
    /// How the name is looked for.
    kind: ImportKind,
    /// Path of the file the name resolved to.
    path: []const u8 = "",
};

/// How the name of an `Import` is looked for.
pub const ImportKind = enum {
    /// An `@import` of a path, looked for beside the importing file.
    file,
    /// An `@import` of a module name, looked up in what the build gave the module.
    module,
    /// A `@cInclude` or an `#include`, looked for in the include directories.
    include,
};

/// One parameter of a function-like declaration.
pub const Param = struct {
    /// The name of the parameter, empty when the source gives it none.
    name: []const u8,
    /// The type as written. Empty for a parameter that was documented in C and that the
    /// signature does not have.
    type_name: []const u8 = "",
    /// What the documentation says about the parameter.
    doc: Text = .{},
};

/// What a declaration is.
pub const Kind = enum {
    /// A function, or in C a function prototype.
    function,
    /// A Zig function that returns a container, which is read as that container.
    type_function,
    /// A struct.
    @"struct",
    /// An enum.
    @"enum",
    /// A union.
    @"union",
    /// A Zig opaque type.
    @"opaque",
    /// A Zig error set.
    error_set,
    /// One error of an error set.
    error_value,
    /// A Zig `const` that is none of the other kinds.
    constant,
    /// A Zig `var`, or a C variable.
    variable,
    /// A field of a container, or one value of a Zig enum. In C, a field that is a
    /// function pointer carries parameters and a return type like a function.
    field,
    /// One value of a C enum.
    enumerator,
    /// A Zig `const` whose value is an `@import` or a `@cImport`.
    import,
    /// A Zig `const` whose value is a path to another declaration.
    alias,
    /// A C `typedef` that declares no container.
    typedef,
    /// A C `#define`.
    macro,
};

/// One declaration. `value` is the initial value of a constant or the default of a field,
/// the imported name of an `import` and the aliased expression of an `alias`. `target` is
/// the path of the file an `import` resolved to, or the identifier of the declaration an
/// `alias` names. An example is source code that uses the declaration, taken from a test.
pub const Decl = struct {
    /// Identifier of the declaration, unique in the document.
    id: []const u8,
    /// The name of the declaration alone, without its containers.
    name: []const u8,
    /// What the declaration is.
    kind: Kind,
    /// Whether the declaration is visible outside its file. Everything in C is.
    public: bool = true,
    /// First line of the declaration in its file, counted from 1.
    line: u32 = 0,
    /// Last line of the declaration in its file.
    end_line: u32 = 0,
    /// The declaration as written, without its body.
    signature: []const u8 = "",
    /// The documentation of the declaration, without what is said of its parameters and
    /// of what it returns.
    doc: Text = .{},
    /// The parameters of a function-like declaration, in order.
    params: []const Param = &.{},
    /// The return type of a function-like declaration, as written.
    return_type: []const u8 = "",
    /// What the documentation says is returned.
    returns: Text = .{},
    /// The type of a field, a constant or a variable, as written, when the source states it.
    type_name: []const u8 = "",
    /// An expression of the source whose meaning depends on `kind`.
    value: []const u8 = "",
    /// What an `import` or an `alias` leads to. Empty when it leads outside the document.
    target: []const u8 = "",
    /// The bodies of the tests named after the declaration.
    examples: []const []const u8 = &.{},
    /// The declarations inside a container, in source order.
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
