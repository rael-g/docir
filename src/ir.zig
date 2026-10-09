//! The intermediate representation: what every reader produces and every writer consumes.
//!
//! A `Document` is a tree of symbols and the list of files they were read from. A reader
//! turns sources of one language into a document, a linker joins several documents and
//! resolves the names they mention, and a writer renders the result. Outside a process the
//! document is JSON whose fields are the fields declared here, under the same names.
//!
//! Nothing here belongs to one language or to one output. A `Symbol` carries the words of
//! its language verbatim, in `Symbol.signature`, `Symbol.form` and `Symbol.modifiers`, and a
//! neutral `Kind` beside them for a writer that does not know the language. Documentation
//! is a `Text`: a tree of blocks and inlines with no markup in it. A reader parses the
//! markup of its language into that tree, whatever that markup is, and a writer produces
//! the markup of its output from it.
//!
//! A symbol is identified by an opaque string that its reader chooses and that is unique in
//! the document. Readers prefix it with their language and use the name the language itself
//! gives the symbol when there is one. Every reference in a document is such an identifier.

const std = @import("std");

/// Version of the JSON layout. A document carrying another one is refused.
pub const format_version = 2;

/// The symbols read from a set of sources.
pub const Document = struct {
    /// The `format_version` the document was written in.
    format: u32 = format_version,
    /// Whether a linker went over the document. Before that, a reference has a target only
    /// where the reader knew it.
    linked: bool = false,
    /// Directory on disk that every `File.path` is relative to. Empty when the document is
    /// not meant to name the machine it was read on.
    source_root: []const u8 = "",
    /// Every file that was read, each under a path no other has.
    files: []const File = &.{},
    /// The symbols that sit inside no other.
    symbols: []const Symbol = &.{},
};

/// One source file.
pub const File = struct {
    /// Path of the file, with `/` between its parts. It identifies the file.
    path: []const u8,
    /// The language of the file, in lower case, as its reader names it.
    language: []const u8,
    /// Whether the file is part of what is being documented. A file that is not was read
    /// only so that references into it resolve.
    documented: bool = true,
    /// What the file imports or includes, in source order.
    imports: []const Import = &.{},
};

/// Something a file pulls in.
pub const Import = struct {
    /// The name as written in the source.
    name: []const u8,
    /// How the name is looked for.
    kind: ImportKind,
    /// Path of the `File` the name resolved to, or empty when it lies outside the document.
    path: []const u8 = "",
};

/// How the name of an `Import` is looked for.
pub const ImportKind = enum {
    /// A path, looked for beside the importing file.
    file,
    /// A name the build of the project gives a meaning to.
    module,
    /// A path looked for in a list of directories.
    include,
};

/// What a reader makes of one file: the file, and the symbol that stands for it with
/// everything the file declares as its members.
pub const Unit = struct {
    /// The file.
    file: File,
    /// The symbol of the file.
    symbol: Symbol,
};

/// A place a symbol is declared at. A symbol declared in parts has one per part.
pub const Location = struct {
    /// Path of the `File`.
    file: []const u8,
    /// First line of the declaration, counted from 1.
    line: u32 = 0,
    /// Last line of the declaration.
    end_line: u32 = 0,
};

/// What a symbol is, for a writer that does not know its language.
pub const Kind = enum {
    /// A name that only groups other symbols and may be declared in many files.
    namespace,
    /// A source file taken as a symbol, in a language where a file is a scope of its own.
    module,
    /// Anything that can be the type of a value: a struct, a class, an interface, an enum.
    type,
    /// Anything that is called: a function, a method, a constructor.
    function,
    /// Data stored in each value of a type.
    field,
    /// Data of a type that is reached through code, such as a C# property.
    property,
    /// A notification a type lets others subscribe to.
    event,
    /// A named value that does not change.
    constant,
    /// A named value that changes.
    variable,
    /// One of the values of an enumerated type, or one error of an error set.
    enumerator,
    /// Another name for a symbol declared elsewhere.
    alias,
    /// A substitution made on the source before it is compiled.
    macro,
};

/// Who may use a symbol.
pub const Visibility = enum {
    /// Anyone.
    public,
    /// The type that declares it and the types derived from it.
    protected,
    /// The unit that is compiled together with it.
    internal,
    /// The scope that declares it.
    private,
};

/// A type as written in the source, and the symbol it names when that is known.
pub const TypeRef = struct {
    /// The type as written.
    text: []const u8 = "",
    /// Identifier of the symbol the type names. Empty when it names none in the document.
    target: []const u8 = "",
};

/// One parameter of a callable symbol.
pub const Param = struct {
    /// The name of the parameter, empty when the source gives it none.
    name: []const u8,
    /// The type of the parameter. Its text is empty for a parameter that was documented
    /// and that the signature does not have.
    type: TypeRef = .{},
    /// What the documentation says about the parameter.
    doc: Text = .{},
};

/// One parameter that stands for a type.
pub const TypeParam = struct {
    /// The name of the parameter.
    name: []const u8,
    /// What a type must satisfy to be given, as written.
    constraint: []const u8 = "",
    /// What the documentation says about the parameter.
    doc: Text = .{},
};

/// A failure a callable symbol is documented to raise or return.
pub const Raised = struct {
    /// The type or the name of the failure.
    type: TypeRef = .{},
    /// When it happens.
    doc: Text = .{},
};

/// Source code that uses a symbol.
pub const Example = struct {
    /// The language of the code, as a fenced block would name it.
    language: []const u8 = "",
    /// The code.
    code: []const u8,
};

/// One declared thing.
pub const Symbol = struct {
    /// Identifier of the symbol, unique in the document.
    id: []const u8,
    /// The name of the symbol alone.
    name: []const u8,
    /// The name of the symbol with the names of the symbols around it, as its language
    /// writes a path to it.
    qualified_name: []const u8,
    /// What the symbol is.
    kind: Kind,
    /// What the symbol is in the words of its language: a struct, an interface, a
    /// constructor. Empty when `kind` says it all.
    form: []const u8 = "",
    /// Who may use the symbol.
    visibility: Visibility = .public,
    /// The other words its language puts on the declaration, such as "static" or "unsafe".
    modifiers: []const []const u8 = &.{},
    /// Where the symbol is declared.
    locations: []const Location = &.{},
    /// The declaration as written, without its body.
    signature: []const u8 = "",
    /// The documentation of the symbol, without what is said of its parameters, of what it
    /// returns and of what it raises.
    doc: Text = .{},
    /// The name of the symbol whose documentation this one asks to be given, as written.
    /// Empty when it asks for that of the member it overrides or implements, and null when
    /// it asks for none. A linker answers it by filling what the symbol does not say itself.
    inherits: ?[]const u8 = null,
    /// The parameters that stand for types, in order.
    type_params: []const TypeParam = &.{},
    /// The parameters of a callable symbol, in order.
    params: []const Param = &.{},
    /// The type of a field, a property, a constant or a variable, and the type a callable
    /// symbol returns.
    type: TypeRef = .{},
    /// What the documentation says is returned.
    returns: Text = .{},
    /// The failures the documentation says are raised.
    raises: []const Raised = &.{},
    /// The types a type is derived from or implements.
    bases: []const TypeRef = &.{},
    /// The initial value of a constant, the default of a field, the expansion of a macro or
    /// the expression an alias stands for, as written.
    value: []const u8 = "",
    /// Identifier of the symbol an alias stands for. Empty when it lies outside the document.
    target: []const u8 = "",
    /// Code that uses the symbol.
    examples: []const Example = &.{},
    /// Sentences that the tests beside the symbol state and check.
    verified: []const []const u8 = &.{},
    /// The symbols declared inside this one, in source order.
    members: []const Symbol = &.{},

    /// Whether the symbol, or a symbol inside it, carries documentation of any kind or an
    /// example. A writer for people leaves out the symbols for which this is false.
    pub fn hasDocumentation(symbol: Symbol) bool {
        if (!symbol.doc.isEmpty() or !symbol.returns.isEmpty() or symbol.examples.len != 0) return true;
        for (symbol.params) |param| {
            if (!param.doc.isEmpty()) return true;
        }
        for (symbol.type_params) |param| {
            if (!param.doc.isEmpty()) return true;
        }
        for (symbol.raises) |raised| {
            if (!raised.doc.isEmpty()) return true;
        }
        for (symbol.members) |member| {
            if (member.hasDocumentation()) return true;
        }
        return false;
    }
};

/// Documentation as structure: a sequence of blocks.
pub const Text = struct {
    /// The blocks, in order. None when there is no documentation.
    blocks: []const Block = &.{},

    /// Whether there is nothing to read.
    pub fn isEmpty(text: Text) bool {
        return text.blocks.len == 0;
    }
};

/// A piece of text that stands on its own lines.
pub const Block = union(enum) {
    /// Running text.
    paragraph: []const Inline,
    /// A title inside the text.
    heading: Heading,
    /// Source code, kept verbatim.
    code: Code,
    /// A sequence of items.
    list: List,
    /// Text quoted from elsewhere.
    quote: []const Block,
    /// Text set apart under a label, such as a note or a warning.
    note: Note,
    /// Rows of cells.
    table: Table,
    /// A separation between two parts of the text.
    rule,
};

/// A title and how deep it sits.
pub const Heading = struct {
    /// Between 1, the outermost, and 6.
    level: u8,
    /// The title.
    content: []const Inline,
};

/// A block of source code.
pub const Code = struct {
    /// The language of the code, empty when it is not stated.
    language: []const u8 = "",
    /// The code, without a trailing line ending.
    text: []const u8,
};

/// A list and the blocks of each of its items.
pub const List = struct {
    /// The number of the first item, or null when the items are not numbered.
    start: ?u32 = null,
    /// The items, each a sequence of blocks.
    items: []const []const Block,
};

/// Blocks under a label.
pub const Note = struct {
    /// The label, as its reader names it, such as "note" or "warning".
    label: []const u8,
    /// What the note says.
    blocks: []const Block,
};

/// A table. Every row has one cell per column.
pub const Table = struct {
    /// The cells of the heading row. None when the table has no heading.
    header: []const []const Inline = &.{},
    /// The other rows.
    rows: []const []const []const Inline = &.{},
};

/// A piece of text inside a line.
pub const Inline = union(enum) {
    /// Plain characters.
    text: []const u8,
    /// Characters of source code that name no symbol.
    code: []const u8,
    /// A mention of a symbol.
    ref: Ref,
    /// A mention of a parameter of the symbol being documented, by its name.
    param: []const u8,
    /// Text that is stressed.
    emphasis: []const Inline,
    /// Text that is stressed more.
    strong: []const Inline,
    /// Text that leads somewhere outside the document.
    link: Link,
    /// A picture, by where it is and what stands for it when it cannot be shown.
    image: Link,
    /// The end of a line that the author asked to be kept.
    line_break,
};

/// A mention of a symbol by the name the author wrote.
pub const Ref = struct {
    /// The name as written.
    text: []const u8,
    /// Identifier of the symbol. Empty when the name was not resolved.
    target: []const u8 = "",
};

/// Text and the address it leads to.
pub const Link = struct {
    /// The address.
    url: []const u8,
    /// What is shown.
    content: []const Inline = &.{},
};

/// The characters of `text` with nothing of its structure: the blocks one after another,
/// a blank line between two, and a mention shown as the name that was written.
pub fn plainText(arena: std.mem.Allocator, text: Text) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try plainBlocks(arena, &out, text.blocks);
    return out.toOwnedSlice(arena);
}

fn plainBlocks(arena: std.mem.Allocator, out: *std.ArrayList(u8), blocks: []const Block) std.mem.Allocator.Error!void {
    for (blocks, 0..) |block, index| {
        if (index != 0) try out.appendSlice(arena, "\n\n");
        switch (block) {
            .paragraph => |content| try plainInlines(arena, out, content),
            .heading => |heading| try plainInlines(arena, out, heading.content),
            .code => |code| try out.appendSlice(arena, code.text),
            .list => |list| for (list.items, 0..) |item, at| {
                if (at != 0) try out.append(arena, '\n');
                try plainBlocks(arena, out, item);
            },
            .quote => |quoted| try plainBlocks(arena, out, quoted),
            .note => |note| try plainBlocks(arena, out, note.blocks),
            .table => |table| {
                var first = true;
                if (table.header.len != 0) {
                    try plainRow(arena, out, table.header);
                    first = false;
                }
                for (table.rows) |row| {
                    if (!first) try out.append(arena, '\n');
                    first = false;
                    try plainRow(arena, out, row);
                }
            },
            .rule => {},
        }
    }
}

fn plainRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), cells: []const []const Inline) std.mem.Allocator.Error!void {
    for (cells, 0..) |cell, index| {
        if (index != 0) try out.append(arena, '\t');
        try plainInlines(arena, out, cell);
    }
}

fn plainInlines(arena: std.mem.Allocator, out: *std.ArrayList(u8), inlines: []const Inline) std.mem.Allocator.Error!void {
    for (inlines) |piece| switch (piece) {
        .text, .code, .param => |characters| try out.appendSlice(arena, characters),
        .ref => |ref| try out.appendSlice(arena, ref.text),
        .emphasis, .strong => |content| try plainInlines(arena, out, content),
        .link, .image => |link| try plainInlines(arena, out, link.content),
        .line_break => try out.append(arena, '\n'),
    };
}

/// Writes `document` as indented JSON.
pub fn writeJson(writer: *std.Io.Writer, document: Document) std.Io.Writer.Error!void {
    try std.json.Stringify.value(document, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

/// Reads a `Document` back. Fails with `error.UnsupportedFormat` when it was written in
/// another `format_version`, and with the JSON parser's error when it is not a document.
pub fn readJson(arena: std.mem.Allocator, bytes: []const u8) !Document {
    const document = try std.json.parseFromSliceLeaky(Document, arena, bytes, .{});
    if (document.format != format_version) return error.UnsupportedFormat;
    return document;
}

test "a document survives the trip through JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const original: Document = .{
        .linked = true,
        .files = &.{.{ .path = "a.h", .language = "c", .documented = false, .imports = &.{.{ .name = "b.h", .kind = .include, .path = "b.h" }} }},
        .symbols = &.{.{
            .id = "c:a.h#pool",
            .name = "pool",
            .qualified_name = "pool",
            .kind = .type,
            .form = "struct",
            .locations = &.{.{ .file = "a.h", .line = 3, .end_line = 9 }},
            .signature = "typedef struct pool",
            .doc = .{ .blocks = &.{
                .{ .paragraph = &.{ .{ .text = "A " }, .{ .strong = &.{.{ .text = "\"quoted\"" }} }, .{ .ref = .{ .text = "pool", .target = "c:a.h#pool" } } } },
                .{ .code = .{ .language = "c", .text = "pool p;\nwait(&p);" } },
                .{ .list = .{ .start = 1, .items = &.{&.{.{ .paragraph = &.{.{ .code = "x" }} }}} } },
                .{ .note = .{ .label = "note", .blocks = &.{.rule} } },
                .{ .table = .{ .header = &.{&.{.{ .text = "h" }}}, .rows = &.{&.{&.{.line_break}}} } },
            } },
            .members = &.{.{
                .id = "c:a.h#pool.wait",
                .name = "wait",
                .qualified_name = "pool.wait",
                .kind = .field,
                .visibility = .private,
                .modifiers = &.{"const"},
                .signature = "bool (*wait)(pool *self)",
                .params = &.{.{ .name = "self", .type = .{ .text = "pool *", .target = "c:a.h#pool" }, .doc = .{ .blocks = &.{.{ .paragraph = &.{.{ .param = "self" }} }} } }},
                .type = .{ .text = "bool" },
                .raises = &.{.{ .type = .{ .text = "E" } }},
                .examples = &.{.{ .language = "c", .code = "p.wait(&p);" }},
                .verified = &.{"it waits"},
            }},
        }},
    };

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeJson(&out.writer, original);
    const copy = try readJson(arena.allocator(), out.written());

    try std.testing.expectEqualDeep(original, copy);
}

test "plain text keeps the characters and drops the structure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text: Text = .{ .blocks = &.{
        .{ .paragraph = &.{ .{ .text = "Calls " }, .{ .ref = .{ .text = "wait" } }, .{ .text = " " }, .{ .strong = &.{.{ .text = "once" }} }, .{ .text = "." } } },
        .{ .list = .{ .items = &.{ &.{.{ .paragraph = &.{.{ .text = "one" }} }}, &.{.{ .paragraph = &.{.{ .code = "two" }} }} } } },
    } };
    try std.testing.expectEqualStrings("Calls wait once.\n\none\ntwo", try plainText(arena.allocator(), text));
}

test "a document written in another format version is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFormat, readJson(arena.allocator(), "{\"format\": 1}"));
}
